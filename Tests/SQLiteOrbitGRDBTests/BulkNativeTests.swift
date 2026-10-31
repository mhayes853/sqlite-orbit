// swift-format-ignore-file: NoAssignmentInExpressions

// GRDB compound column operators return SQL assignments without mutating their operands.
import Foundation
import SQLiteOrbit
import SQLiteOrbitGRDB
import Testing
import XCTest

private struct BulkNativeRecord: Codable, FetchableRecord, TableRecord, Sendable {
  static let databaseTableName = "t"
  var id: Int
  var n: Int
}

private final class BulkDerivationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

class BulkNativeTests: GRDBTestCase {
  func testInvalidGroupingIsRejectedBeforeMutation() throws {
    let database = try makeDatabaseQueue()
    try database.write { db in
      try db.execute(
        sql: "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER); INSERT INTO t VALUES (1,10),(2,10)"
      )
      let request = Table<SQLiteOrbitGRDB.Row>("t").all().group(Column("n"))
      XCTAssertThrowsError(try request.deleteAll(db))
      XCTAssertThrowsError(try request.updateAll(db, Column("n").set(to: 0)))
      XCTAssertThrowsError(try request.deleteAndFetchStatement(db, selection: [AllColumns()]))
      XCTAssertThrowsError(
        try request.updateAndFetchStatement(db, [Column("n").set(to: 0)], selection: [AllColumns()])
      )
      XCTAssertEqual(try Int.fetchAll(db, sql: "SELECT n FROM t"), [10, 10])
    }
  }

  func testGroupedDerivationsResolveOnceAndIgnoreTheRequestSelection() throws {
    let database = try makeDatabaseQueue()
    let groups = BulkDerivationCounter()
    let filters = BulkDerivationCounter()
    let orders = BulkDerivationCounter()
    try database.write { db in
      try db.execute(
        sql: "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER); INSERT INTO t VALUES (1,10),(2,20)"
      )
      let request = BulkNativeRecord.all()
        .groupWhenConnected { _ in
          groups.increment()
          return [Column("id")]
        }
        .filterWhenConnected { _ in
          filters.increment()
          return Column("n") > 0
        }
        .orderWhenConnected { _ in
          orders.increment()
          return [Column("id").desc]
        }
        .selectWhenConnected { _ in throw DatabaseError(message: "ignored selection") }
        .limit(1)
      let records = try request.updateAndFetchAll(db, [Column("n") += 1])
      XCTAssertEqual(records.map(\.id), [2])
      XCTAssertEqual(groups.value, 1)
      XCTAssertEqual(filters.value, 1)
      XCTAssertEqual(orders.value, 1)
    }
  }

  func testPartiallyConsumedCursorCannotEscapeButItsChangesCommit() throws {
    let database = try makeDatabaseQueue()
    let cursor = try database.writeWithoutTransaction { db in
      try db.execute(
        sql: "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER); INSERT INTO t VALUES (1,10),(2,20)"
      )
      let cursor = try BulkNativeRecord.all().updateAndFetchCursor(db, [Column("n") += 1])
      XCTAssertNotNil(try cursor.next())
      return cursor
    }
    XCTAssertThrowsError(try cursor.next()) { error in
      XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_MISUSE)
    }
    XCTAssertEqual(
      try database.read { try Int.fetchAll($0, sql: "SELECT n FROM t ORDER BY id") },
      [11, 21]
    )
  }
  func testCompositePrimaryKeyGroupingWithoutRowID() throws {
    let database = try makeDatabaseQueue()
    try database.write { db in
      try db.execute(
        sql:
          "CREATE TABLE composite(a TEXT, b INTEGER, n INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID; INSERT INTO composite VALUES ('x',1,10),('x',2,20),('y',1,30)"
      )
      let request = Table<SQLiteOrbitGRDB.Row>("composite").all().group([Column("a"), Column("b")])
        .having(Column("n") >= 20)
      let statement = try request.updateAndFetchStatement(
        db,
        [Column("n") += 5],
        selection: [Column("n")]
      )
      XCTAssertEqual(try Int.fetchSet(statement), [25, 35])
      XCTAssertEqual(try request.deleteAll(db), 2)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT n FROM composite"), 10)
    }
  }
}

@Suite("GRDB bulk native drivers", .timeLimit(.minutes(1)))
struct BulkNativeDriverTests {
  @Test
  func partiallyConsumedReturningCursorsNotifyIPCPeers() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: file.path + suffix)
      }
    }
    let network = InMemoryIPCTransport.Network()
    let first = OrbitIPCDatabase(
      writer: try SQLitePool(path: OrbitDatabasePath(file.path)),
      transport: InMemoryIPCTransport(network: network)
    )
    let second = OrbitIPCDatabase(
      writer: try SQLitePool(path: OrbitDatabasePath(file.path)),
      transport: InMemoryIPCTransport(network: network)
    )
    try await first.write { (db: SQLiteOrbitGRDB.Database) in
      try db.execute(
        sql: "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER); INSERT INTO t VALUES (1,1),(2,2)"
      )
    }
    var iterator = SQLiteOrbitGRDB.ValueObservation
      .tracking { db in
        try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(n),0) FROM t")!
      }
      .values(in: second).makeAsyncIterator()
    #expect(try await iterator.next() == 3)
    try await first.write { db in
      let cursor = try BulkNativeRecord.all().updateAndFetchCursor(db, [Column("n") += 10])
      #expect(try cursor.next() != nil)
    }
    #expect(try await iterator.next() == 23)
    try await first.writeWithoutTransaction { (db: SQLiteOrbitGRDB.Database) in
      let cursor = try BulkNativeRecord.all().deleteAndFetchCursor(db)
      #expect(try cursor.next() != nil)
    }
    #expect(try await iterator.next() == 0)
  }

  #if Turso
    @Test
    func tursoBulkReturningUsesTheNativeDriver() async throws {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: file) }
      let database = try TursoPool(path: OrbitDatabasePath(file.path))
      try await database.write { (db: SQLiteOrbitGRDB.Database) in
        try db.execute(
          sql:
            "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER); INSERT INTO t VALUES (1,10),(2,20)"
        )
        let records = try BulkNativeRecord.all().updateAndFetchAll(db, [Column("n") += 1])
        #expect(records.map(\.n).sorted() == [11, 21])
        let statement = try BulkNativeRecord.filter(key: 1)
          .deleteAndFetchStatement(db, selection: [Column("id")])
        #expect(try Int.fetchAll(statement) == [1])
      }
    }
  #endif
}
