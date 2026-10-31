import Dispatch
import Foundation
import SQLiteOrbit
import SQLiteOrbitGRDB
import XCTest

// A public native-driver seam that can fail before lending a connection or after its cleanup.
private final class CallbackAccessDriver: OrbitDatabaseWriter, OrbitObservableDatabase,
  SQLiteOrbitGRDB.DatabaseWriter, @unchecked Sendable
{
  enum Failure { case none, beforeAccess, afterAccess }
  let queue: SQLiteOrbit.SQLiteQueue
  let failure: Failure
  private let lock = NSLock()
  private var loans = 0

  init(failure: Failure = .none) throws {
    queue = try SQLiteOrbit.SQLiteQueue(path: .memory)
    self.failure = failure
  }

  var orbitDatabase: any OrbitObservableDatabaseWriter { self }
  var accessCount: Int { lock.withLock { loans } }

  private func beforeAccess() throws {
    lock.withLock { loans += 1 }
    if failure == .beforeAccess { throw SQLiteError(code: .busy, message: "before access") }
  }

  private func afterAccess<T>(_ result: T) throws -> T {
    if failure == .afterAccess { throw SQLiteError(code: .busy, message: "after access") }
    return result
  }

  func read<T: Sendable>(_ body: sending (borrowing SQLiteReadTransaction) throws -> T) async throws
    -> T
  {
    try beforeAccess()
    return try afterAccess(await queue.read(body))
  }
  func readBlocking<T: Sendable>(_ body: sending (borrowing SQLiteReadTransaction) throws -> T)
    throws -> T
  {
    try queue.readBlocking(body)
  }
  func readWithoutTransaction<T: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> T
  ) async throws -> T {
    try beforeAccess()
    return try afterAccess(await queue.readWithoutTransaction(body))
  }
  func readWithoutTransactionBlocking<T: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> T
  ) throws -> T {
    try queue.readWithoutTransactionBlocking(body)
  }
  func write<T: Sendable>(_ body: sending (borrowing SQLiteWriteTransaction) throws -> T)
    async throws -> T
  {
    try await queue.write(body)
  }
  func writeBlocking<T: Sendable>(_ body: sending (borrowing SQLiteWriteTransaction) throws -> T)
    throws -> T
  {
    try queue.writeBlocking(body)
  }
  func writeWithoutTransaction<T: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> T
  ) async throws -> T {
    try beforeAccess()
    return try afterAccess(await queue.writeWithoutTransaction(body))
  }
  func writeWithoutTransactionBlocking<T: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> T
  ) throws -> T {
    try queue.writeWithoutTransactionBlocking(body)
  }
  func subscribe(
    transactionObserver: any OrbitDatabaseTransactionObserver,
    region: OrbitDatabaseRegion
  ) throws -> OrbitRegionSubscription {
    try queue.subscribe(transactionObserver: transactionObserver, region: region)
  }
}

class CallbackAccessNativeTests: XCTestCase {
  func testAcquisitionFailuresAreTranslatedAndDelivered() throws {
    let driver = try CallbackAccessDriver(failure: .beforeAccess)
    let reader: any DatabaseReader = driver
    let readDone = expectation(description: "read failure")
    reader.asyncUnsafeRead { result in
      if case .failure(let error) = result {
        XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_BUSY)
      } else {
        XCTFail("Expected acquisition failure")
      }
      readDone.fulfill()
    }
    let migrationDone = expectation(description: "migration acquisition failure")
    DatabaseMigrator()
      .asyncMigrate(driver) { result in
        if case .failure(let error) = result {
          XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_BUSY)
        } else {
          XCTFail("Expected acquisition failure")
        }
        migrationDone.fulfill()
      }
    wait(for: [readDone, migrationDone], timeout: 5)
  }

  func testCleanupFailuresDoNotDeliverASecondResult() throws {
    let driver = try CallbackAccessDriver(failure: .afterAccess)
    let reader: any DatabaseReader = driver
    let successes = expectation(description: "three scoped successes")
    successes.expectedFulfillmentCount = 3
    let duplicate = expectation(description: "no callback after cleanup failure")
    duplicate.isInverted = true
    let completion: @Sendable (Result<SQLiteOrbitGRDB.Database, Error>) -> Void = { result in
      switch result {
      case .success: successes.fulfill()
      case .failure: duplicate.fulfill()
      }
    }
    reader.asyncRead(completion)
    reader.asyncUnsafeRead(completion)
    DatabaseMigrator().asyncMigrate(driver, completion: completion)
    wait(for: [successes], timeout: 5)
    wait(for: [duplicate], timeout: 0.05)
  }

  func testMigrationCompletesWithinItsOriginalWriterLoan() throws {
    let driver = try CallbackAccessDriver()
    var migrator = DatabaseMigrator()
    migrator.registerMigration("create") { db in
      try db.execute(sql: "CREATE TEMP TABLE marker(n); INSERT INTO marker VALUES (42)")
    }
    let done = expectation(description: "migration completion")
    migrator.asyncMigrate(driver) { result in
      do {
        let db = try result.get()
        XCTAssertFalse(db.isInsideTransaction)
        XCTAssertEqual(driver.accessCount, 1)
        let marker = try Int.fetchOne(db, sql: "SELECT n FROM marker")
        XCTAssertEqual(marker, 42)
        try db.execute(sql: "INSERT INTO marker VALUES (43)")
      } catch { XCTFail("Unexpected error: \(error)") }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    let rows = try (driver as any DatabaseWriter)
      .read { try Int.fetchAll($0, sql: "SELECT n FROM marker") }
    XCTAssertEqual(rows, [42, 43])
  }

  func testUnsafeReadStaysReadOnlyAndDoesNotHoldASnapshot() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: file.path + suffix)
      }
    }
    let reader = try DatabasePool(path: file.path)
    let other = try DatabaseQueue(path: file.path)
    try other.write { try $0.execute(sql: "CREATE TABLE item(n); INSERT INTO item VALUES (1)") }
    let done = expectation(description: "nontransactional read")
    reader.asyncUnsafeRead { result in
      do {
        let db = try result.get()
        XCTAssertFalse(db.isInsideTransaction)
        do {
          try db.execute(sql: "INSERT INTO item VALUES (3)")
          XCTFail("Expected read-only access")
        } catch let error as DatabaseError {
          XCTAssertEqual(error.resultCode, .SQLITE_READONLY)
        }
        let before = try Int.fetchOne(db, sql: "SELECT n FROM item")
        XCTAssertEqual(before, 1)
        try other.write { try $0.execute(sql: "UPDATE item SET n=2") }
        let after = try Int.fetchOne(db, sql: "SELECT n FROM item")
        XCTAssertEqual(after, 2)
      } catch { XCTFail("Unexpected error: \(error)") }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    let queueDone = expectation(description: "queue also enforces read-only access")
    other.asyncUnsafeRead { result in
      do {
        let db = try result.get()
        do {
          try db.execute(sql: "INSERT INTO item VALUES (3)")
          XCTFail("Expected read-only queue access")
        } catch let error as DatabaseError { XCTAssertEqual(error.resultCode, .SQLITE_READONLY) }
      } catch { XCTFail("Unexpected error: \(error)") }
      queueDone.fulfill()
    }
    wait(for: [queueDone], timeout: 5)
  }
}
