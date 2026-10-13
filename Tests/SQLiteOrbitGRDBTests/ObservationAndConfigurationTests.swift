import Dispatch
import Foundation
import SQLiteOrbitGRDB
import Testing

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
@Suite("GRDB observation and configuration", .timeLimit(.minutes(1)))
struct ObservationAndConfigurationTests {
  @Test func everyPoolConnectionIsPrepared() async throws {
    let count = Counter()
    var configuration = Configuration()
    configuration.maximumReaderCount = 2
    configuration.prepareDatabase { db in
      count.increment()
      db.add(
        function: DatabaseFunction("twice", argumentCount: 1, pure: true) { values in
          Int.fromDatabaseValue(values[0]).map { $0 * 2 }
        }
      )
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".sqlite"
    )
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: file.path + suffix)
      }
    }
    let pool = try DatabasePool(path: file.path, configuration: configuration)
    #expect(count.value == 3)
    #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT twice(21)") } == 42)
    #expect(try await pool.write { try Int.fetchOne($0, sql: "SELECT twice(10)") } == 20)
  }
  @Test func dynamicRegionsFollowConditionalQueries() async throws {
    let queue = try DatabaseQueue()
    try await queue.write { db in
      try db.execute(
        sql:
          "CREATE TABLE choice(a); INSERT INTO choice VALUES (0); CREATE TABLE a(n); INSERT INTO a VALUES (1); CREATE TABLE b(n); INSERT INTO b VALUES (2)"
      )
    }
    let observation = ValueObservation.tracking { db in
      let table = try Int.fetchOne(db, sql: "SELECT a FROM choice") == 0 ? "a" : "b"
      return try Int.fetchOne(db, sql: "SELECT n FROM \(table)")!
    }
    var iterator = observation.values(in: queue).makeAsyncIterator()
    #expect(try await iterator.next() == 1)
    try await queue.write { try $0.execute(sql: "UPDATE choice SET a=1") }
    #expect(try await iterator.next() == 2)
    try await queue.write { try $0.execute(sql: "UPDATE b SET n=3") }
    #expect(try await iterator.next() == 3)
  }
  @Test func explicitRegionsAndIndependentIterators() async throws {
    let queue = try DatabaseQueue()
    try await queue.write { try $0.execute(sql: "CREATE TABLE t(n); INSERT INTO t VALUES (1)") }
    let observation =
      ValueObservation.trackingConstantRegion(
        Table("t").all(),
        fetch: { db in
          try Int.fetchOne(db, sql: "SELECT n FROM t")!
        }
      )
      .removeDuplicates()
    let values = observation.values(in: queue)
    var first = values.makeAsyncIterator()
    var second = values.makeAsyncIterator()
    #expect(try await first.next() == 1)
    #expect(try await second.next() == 1)
    try await queue.write { try $0.execute(sql: "UPDATE t SET n=2") }
    #expect(try await first.next() == 2)
    #expect(try await second.next() == 2)
  }
  @Test func releasedIteratorCancelsObservation() async throws {
    let queue = try DatabaseQueue()
    let cancellations = Counter()
    let observation = ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT 1")! }
      .handleEvents(didCancel: { cancellations.increment() })
    func consumeOne() async throws {
      var iterator = observation.values(in: queue).makeAsyncIterator()
      #expect(try await iterator.next() == 1)
    }
    try await consumeOne()
    #expect(cancellations.value == 1)
  }
  @Test func cursorReleaseAllowsSchemaChanges() throws {
    let queue = try DatabaseQueue()
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE t(n); INSERT INTO t VALUES(1),(2)")
      func readOne() throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT n FROM t")
        _ = try cursor.next()
      }
      try readOne()
      try db.drop(table: "t")
    }
  }
  @Test func readAccessRefusesWritesAndTranslatesCodes() throws {
    let queue = try DatabaseQueue()
    try queue.write { try $0.execute(sql: "CREATE TABLE t(n NOT NULL UNIQUE)") }
    do {
      try queue.read { try $0.execute(sql: "INSERT INTO t VALUES(1)") }
      Issue.record("write succeeded through read access")
    } catch DatabaseError.SQLITE_READONLY {}
    do {
      try queue.write { try $0.execute(sql: "INSERT INTO t VALUES(NULL)") }
      Issue.record("not-null constraint succeeded")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
      #expect(error.extendedResultCode == .SQLITE_CONSTRAINT_NOTNULL)
      #expect(error.sql?.contains("INSERT") == true)
    }
  }
  @Test func enumsEncodeAsSQLScalars() throws {
    enum Status: String, Codable { case ready }
    struct Item: Codable, FetchableRecord, PersistableRecord, Equatable {
      let id: Int
      let status: Status
    }
    let queue = try DatabaseQueue()
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE item(id INTEGER PRIMARY KEY, status TEXT)")
      try Item(id: 1, status: .ready).insert(db)
      #expect(try String.fetchOne(db, sql: "SELECT status FROM item") == "ready")
      #expect(try Item.fetchOne(db, id: 1) == Item(id: 1, status: .ready))
    }
  }
}
