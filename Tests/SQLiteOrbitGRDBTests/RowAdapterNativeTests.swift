import Foundation
import SQLiteOrbit
import SQLiteOrbitGRDB
import Testing
import XCTest

private final class AdapterCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  func increment() { lock.withLock { calls += 1 } }
  var value: Int { lock.withLock { calls } }
}

private struct CountingRowAdapter: RowAdapter {
  let counter: AdapterCallCounter
  func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
    counter.increment()
    return try SuffixRowAdapter(fromIndex: 1)._layoutedAdapter(from: layout)
  }
}

private struct LegacyAdapterRequest: FetchRequest {
  typealias RowDecoder = Int
  var cached: Bool { true }
  func sql(in db: SQLiteOrbitGRDB.Database) throws -> SQLiteOrbitGRDB.SQL { "SELECT 42" }
}

private struct PreparedAdapterRequest: FetchRequest {
  typealias RowDecoder = Int
  let hints: AdapterCallCounter
  func sql(in db: SQLiteOrbitGRDB.Database) throws -> SQLiteOrbitGRDB.SQL {
    throw DatabaseError(message: "Fetching must use the preparation hook")
  }
  func makePreparedRequest(_ db: SQLiteOrbitGRDB.Database, forSingleResult singleResult: Bool)
    throws -> PreparedRequest
  {
    if singleResult { hints.increment() }
    return try SQLRequest<Int>(sql: "SELECT 99, 42", adapter: SuffixRowAdapter(fromIndex: 1))
      .makePreparedRequest(db)
  }
}

class RowAdapterNativeTests: GRDBTestCase {
  func testLayoutResolvesOncePerCursorBeforeStepping() throws {
    try makeDatabaseQueue()
      .read { db in
        let counter = AdapterCallCounter()
        let request = SQLRequest<Int>(
          sql: "SELECT 99, 1 UNION ALL SELECT 99, 2",
          adapter: CountingRowAdapter(counter: counter),
          cached: true
        )
        let cursor = try request.fetchCursor(db)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try Array(cursor), [1, 2])
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try request.fetchAll(db), [1, 2])
        XCTAssertEqual(counter.value, 2)
      }
  }

  func testExistingRequestsKeepWorkingAndPreparationOverridesAreRespected() throws {
    try makeDatabaseQueue()
      .read { db in
        XCTAssertEqual(try LegacyAdapterRequest().fetchAll(db), [42])
        XCTAssertEqual(try LegacyAdapterRequest().fetchOne(db), 42)
        let hints = AdapterCallCounter()
        let request = PreparedAdapterRequest(hints: hints)
        XCTAssertEqual(try request.fetchOne(db), 42)
        XCTAssertEqual(try Int.fetchOne(db, request), 42)
        XCTAssertEqual(try SQLiteOrbitGRDB.Row.fetchOne(db, request)![0] as Int, 42)
        XCTAssertEqual(hints.value, 3)
        XCTAssertEqual(try request.fetchAll(db), [42])
        XCTAssertEqual(try Int.fetchAll(db, request), [42])
        XCTAssertEqual(hints.value, 3)
      }
  }

  func testRequestTypeConversionPreservesAdapter() throws {
    try makeDatabaseQueue()
      .read { db in
        let request = SQLRequest<SQLiteOrbitGRDB.Row>(
          sql: "SELECT 99, 42",
          adapter: SuffixRowAdapter(fromIndex: 1),
          cached: true
        )
        XCTAssertEqual(try request.asRequest(of: Int.self).fetchAll(db), [42])
      }
  }

  func testEmptyScalarProjectionThrowsInsteadOfIndexingPastTheRow() throws {
    try makeDatabaseQueue()
      .read { db in
        XCTAssertThrowsError(try Int.fetchOne(db, sql: "SELECT 1", adapter: EmptyRowAdapter()))
        XCTAssertThrowsError(
          try Int.fetchOne(db.makeStatement(sql: "SELECT 1"), adapter: EmptyRowAdapter())
        )
        XCTAssertThrowsError(
          try SQLRequest<Int>(sql: "SELECT 1", adapter: EmptyRowAdapter()).fetchOne(db)
        )
      }
  }

  func testAdaptedCursorCannotEscapeItsAccessButCopiesCan() throws {
    let database = try makeDatabaseQueue()
    let result = try database.read { db in
      let cursor = try SQLiteOrbitGRDB.Row.fetchCursor(
        db,
        sql: "SELECT 99, 42 AS id UNION ALL SELECT 99, 43",
        adapter: ScopeAdapter(
          base: EmptyRowAdapter(),
          scopes: ["item": SuffixRowAdapter(fromIndex: 1)]
        )
      )
      return (cursor, try cursor.next()!.copy())
    }
    XCTAssertThrowsError(try result.0.next()) { error in
      XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_MISUSE)
    }
    XCTAssertEqual(result.1.scopes["item"]!["id"] as Int, 42)
    XCTAssertEqual(result.1.unadapted[0] as Int, 99)
  }

  func testFailedAdapterReleasesCachedCursorAndKeepsRegion() throws {
    try makeDatabaseQueue()
      .write { db in
        try db.execute(sql: "CREATE TABLE item(id); INSERT INTO item VALUES (42)")
        var request = SQLRequest<Int>(
          sql: "SELECT 99, id FROM item",
          adapter: ColumnMapping(["id": "missing"]),
          cached: true
        )
        XCTAssertThrowsError(try request.fetchAll(db))
        request.adapter = SuffixRowAdapter(fromIndex: 1)
        XCTAssertEqual(try request.fetchAll(db), [42])
        let adapted = request.adapted { _ in EmptyRowAdapter() }
        XCTAssertEqual(try adapted.databaseRegion(db), try request.databaseRegion(db))
        XCTAssertEqual(try SQLiteOrbitGRDB.Row.fetchCursor(db, adapted).next()!.count, 0)
      }
  }
}

private struct AdapterDriverItem: Codable, FetchableRecord, Equatable, Sendable {
  let id: Int
  let name: String
}

private struct AdapterDriverJoined: Decodable, FetchableRecord, Equatable, Sendable {
  let item: AdapterDriverItem
}

@Suite("GRDB row adapter drivers", .timeLimit(.minutes(1)))
struct RowAdapterDriverTests {
  private func exercise(_ database: some DatabaseWriter) async throws {
    try await database.write { (db: SQLiteOrbitGRDB.Database) in
      try db.execute(
        sql:
          "CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO item VALUES (1,'Arthur')"
      )
    }
    let request = SQLRequest<AdapterDriverJoined>(
      sql: "SELECT 99 AS unused, id, name FROM item",
      adapter: ScopeAdapter(
        base: EmptyRowAdapter(),
        scopes: ["item": SuffixRowAdapter(fromIndex: 1)]
      ),
      cached: true
    )
    var iterator = SQLiteOrbitGRDB.ValueObservation.tracking { try request.fetchAll($0) }
      .values(in: database).makeAsyncIterator()
    let initial = [AdapterDriverJoined(item: AdapterDriverItem(id: 1, name: "Arthur"))]
    #expect(try await iterator.next() == initial)
    #expect(try await database.read { try request.fetchAll($0) } == initial)
    try await database.write { (db: SQLiteOrbitGRDB.Database) in
      let result = try SQLiteOrbitGRDB.Row.fetchOne(
        db,
        sql: "UPDATE item SET name='Barbara' RETURNING id, name",
        adapter: ScopeAdapter(["item": SuffixRowAdapter(fromIndex: 0)])
      )!
      #expect(try result.decode(AdapterDriverItem.self, forKey: "item").name == "Barbara")
    }
    #expect(
      try await iterator.next() == [
        AdapterDriverJoined(item: AdapterDriverItem(id: 1, name: "Barbara"))
      ]
    )
  }

  @Test
  func queue() async throws {
    try await exercise(SQLiteQueue(path: .memory))
  }

  @Test
  func pool() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { removeDatabase(file) }
    try await exercise(SQLitePool(path: OrbitDatabasePath(file.path)))
  }

  @Test
  func ipcPeerObservationUsesAdaptedRequests() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { removeDatabase(file) }
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
        sql:
          "CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO item VALUES (1,'Arthur')"
      )
    }
    let request = SQLRequest<AdapterDriverJoined>(
      sql: "SELECT id, name FROM item",
      adapter: ScopeAdapter(
        base: EmptyRowAdapter(),
        scopes: ["item": SuffixRowAdapter(fromIndex: 0)]
      )
    )
    var iterator = SQLiteOrbitGRDB.ValueObservation.tracking { try request.fetchAll($0) }
      .values(in: second).makeAsyncIterator()
    #expect(
      try await iterator.next() == [
        AdapterDriverJoined(item: AdapterDriverItem(id: 1, name: "Arthur"))
      ]
    )
    try await first.write { (db: SQLiteOrbitGRDB.Database) in
      try db.execute(sql: "UPDATE item SET name='Barbara'")
    }
    #expect(
      try await iterator.next() == [
        AdapterDriverJoined(item: AdapterDriverItem(id: 1, name: "Barbara"))
      ]
    )
  }

  #if Turso
    @Test
    func tursoRowAdapters() async throws {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { removeDatabase(file) }
      try await exercise(TursoPool(path: OrbitDatabasePath(file.path)))
    }
  #endif

  private func removeDatabase(_ file: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: file.path + suffix)
    }
  }
}
