import Foundation
import SQLiteOrbit
import SQLiteOrbitGRDB
import Testing

private struct Player: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
  var id: Int64?
  var name: String
  var score: Int

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

private struct FixedPlayer: Codable, FetchableRecord, PersistableRecord, Sendable {
  static var databaseTableName: String {
    "player"
  }

  let id: Int64
  var name: String
  var score: Int
}

private func schema(_ db: SQLiteOrbitGRDB.Database) throws {
  try db.create(table: "player") { t in
    t.autoIncrementedPrimaryKey("id")
    t.column("name", .text).notNull()
    t.column("score", .integer).notNull().defaults(to: 0)
  }
}

@Suite("GRDB compatibility", .timeLimit(.minutes(1)))
struct CompatibilityTests {
  @Test
  func rawSQLAndRows() throws {
    let queue = try DatabaseQueue()
    try queue.write { db in
      try db.execute(
        sql: "CREATE TABLE t(a, b, c); INSERT INTO t VALUES (?, :b, ?)",
        arguments: [1, Data()] + ["b": "O'Brien"]
      )
      let row = try #require(try SQLiteOrbitGRDB.Row.fetchOne(db, sql: "SELECT * FROM t"))
      #expect(row["A"] as Int == 1)
      #expect(row["b"] as String == "O'Brien")
      #expect(row["c"] as Data == Data())
      #expect(row["missing"] as String? == nil)
      #expect(try Int.fetchOne(db, sql: "SELECT NULL") == nil)
      let rows = try SQLiteOrbitGRDB.Row.fetchAll(db, sql: "SELECT 1 a UNION ALL SELECT 2")
      #expect(rows[0]["a"] as Int == 1)
      #expect(rows[1]["a"] as Int == 2)
    }
  }

  @Test
  func cursorIsLazyAndRequiresCopies() throws {
    let queue = try DatabaseQueue()
    try queue.read { (db: SQLiteOrbitGRDB.Database) throws in
      let cursor = try SQLiteOrbitGRDB.Row.fetchCursor(db, sql: "SELECT 1 a UNION ALL SELECT 2")
      let row = try #require(try cursor.next())
      let copy = row.copy()
      #expect(try cursor.next() === row)
      #expect(row["a"] as Int == 2)
      #expect(copy["a"] as Int == 1)
      #expect(try cursor.next() == nil)
      #expect(try cursor.next() == nil)
    }
  }

  @Test
  func checkedAccessLifetime() throws {
    let queue = try DatabaseQueue()
    let escaped = try queue.read { $0 }
    #expect(throws: DatabaseError.self) { try Int.fetchOne(escaped, sql: "SELECT 1") }
    let cursor = try queue.read { try SQLiteOrbitGRDB.Row.fetchCursor($0, sql: "SELECT 1") }
    #expect(throws: DatabaseError.self) { try cursor.next() }
    let statement = try queue.read { try $0.makeStatement(sql: "SELECT 1") }
    #expect(throws: DatabaseError.self) { try Int.fetchOne(statement) }
  }

  @Test
  func parameterSyntax() throws {
    let queue = try DatabaseQueue()
    try queue.read { (db: SQLiteOrbitGRDB.Database) throws in
      let row = try #require(
        try SQLiteOrbitGRDB.Row.fetchOne(
          db,
          sql: "SELECT ?2, :x, ?1, :x, ?",
          arguments: [10, 20, 30] + ["x": 40]
        )
      )
      #expect(row.databaseValues == [20, 40, 10, 40, 30].map(\.databaseValue))
      #expect(
        try String.fetchOne(db, sql: "SELECT '?not a parameter' /* ? */ -- :no\n")
          == "?not a parameter"
      )
      #expect(throws: DatabaseError.self) { try Int.fetchOne(db, sql: "SELECT ?", arguments: []) }
    }
  }

  @Test
  func recordsAndQueries() throws {
    let queue = try DatabaseQueue()
    try queue.write { db in
      try schema(db)
      var player = Player(name: "Arthur", score: 100)
      try player.insert(db)
      #expect(player.id == 1)
      #expect(try player.exists(db))
      #expect(try Player.fetchOne(db, id: player.id) == player)
      player.score = 200
      try player.update(db)
      #expect(
        try Player.filter(Column("score") > 100).order(Column("name")).fetchAll(db) == [player]
      )
      #expect(try Player.all().select(Column("score"), as: Int.self).fetchAll(db) == [200])
      #expect(
        try Player.filter(Column("name") == "Arthur").updateAll(db, Column("score").set(to: 300))
          == 1
      )
      #expect(try Player.fetchOne(db, id: 1)?.score == 300)
      #expect(try player.updateChanges(db) { $0.name = "Barbara" })
      #expect(try !player.updateChanges(db) { _ in })
      #expect(try player.delete(db))
      #expect(try !player.exists(db))
      #expect(try !player.delete(db))
      try FixedPlayer(id: 5, name: "New", score: 50).insert(db)
      try FixedPlayer(id: 5, name: "Saved", score: 60).save(db)
      #expect(try Player.fetchOne(db, id: 5)?.name == "Saved")
    }
  }

  @Test
  func transactionsAndSavepoints() throws {
    let queue = try DatabaseQueue()
    try queue.write { try $0.execute(sql: "CREATE TABLE t(a INTEGER)") }
    struct Failure: Error {}
    #expect(throws: Failure.self) {
      try queue.write { db in
        try db.execute(sql: "INSERT INTO t VALUES (1)")
        throw Failure()
      }
    }
    #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t") } == 0)
    try queue.writeWithoutTransaction { db in
      try db.inTransaction {
        try db.execute(sql: "INSERT INTO t VALUES (2)")
        return .rollback
      }
      try db.inTransaction {
        try db.execute(sql: "INSERT INTO t VALUES (3)")
        try db.inSavepoint {
          try db.execute(sql: "INSERT INTO t VALUES (4)")
          return .rollback
        }
        return .commit
      }
    }
    #expect(try queue.read { try Int.fetchAll($0, sql: "SELECT a FROM t") } == [3])
  }

  @Test
  func migrationsAndSchema() throws {
    let queue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1", migrate: schema)
    migrator.registerMigration("v2") { db in
      try db.alter(table: "player") { $0.add(column: "nickname", .text) }
      try db.create(index: "player_name", on: "player", columns: ["name"])
    }
    try migrator.migrate(queue, upTo: "v1")
    #expect(try queue.read { try migrator.appliedMigrations($0) } == ["v1"])
    try migrator.migrate(queue)
    try migrator.migrate(queue)
    try queue.read { (db: SQLiteOrbitGRDB.Database) throws in
      #expect(try db.primaryKey("player").rowIDColumn == "id")
      #expect(try db.columns(in: "player").map(\.name) == ["id", "name", "score", "nickname"])
      #expect(try migrator.hasCompletedMigrations(db))
      #expect(try !db.tableExists("orbit_migrations"))
    }
  }

  @Test
  func directNativeDriverConformance() async throws {
    let native = try SQLiteOrbit.SQLiteQueue(path: .memory)
    try await native.write { db in try db.execute(sql: "CREATE TABLE t(a INTEGER)") }
    try await native.write { (tx: borrowing SQLiteOrbit.SQLiteWriteTransaction) in
      try tx.execute("INSERT INTO t VALUES (1)")
    }
    #expect(try await native.read { db in try Int.fetchAll(db, sql: "SELECT a FROM t") } == [1])
    func count(in writer: some DatabaseWriter) async throws -> Int {
      try await writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t")! }
    }
    #expect(try await count(in: native) == 1)
  }

  @Test
  func observationSeesNativeAndOverlayWrites() async throws {
    let native = try SQLiteOrbit.SQLiteQueue(path: .memory)
    try await native.write { db in try db.execute(sql: "CREATE TABLE t(a INTEGER)") }
    let observation = SQLiteOrbitGRDB.ValueObservation
      .tracking { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t")!
      }
      .map { String($0) }.removeDuplicates()
    var iterator = observation.values(in: native).makeAsyncIterator()
    #expect(try await iterator.next() == "0")
    try await native.write { (tx: borrowing SQLiteOrbit.SQLiteWriteTransaction) in
      try tx.execute("INSERT INTO t VALUES (1)")
    }
    #expect(try await iterator.next() == "1")
    try await native.write { db in try db.execute(sql: "INSERT INTO t VALUES (2)") }
    #expect(try await iterator.next() == "2")
  }

  @Test
  func observationTerminatesOnError() async throws {
    let queue = try DatabaseQueue()
    let observation = SQLiteOrbitGRDB.ValueObservation.tracking { db in
      try Int.fetchOne(db, sql: "SELECT * FROM missing")
    }
    var iterator = observation.values(in: queue).makeAsyncIterator()
    await #expect(throws: DatabaseError.self) { try await iterator.next() }
    #expect(try await iterator.next() == nil)
  }

  @Test
  @MainActor
  func immediateObservationAndCancellation() throws {
    let queue = try DatabaseQueue()
    var values: [Int] = []
    let observation = SQLiteOrbitGRDB.ValueObservation.tracking { db in
      try Int.fetchOne(db, sql: "SELECT 42")!
    }
    let subscription = observation.start(
      in: queue,
      scheduling: .immediate,
      onError: { _ in Issue.record("unexpected observation error") },
      onChange: { values.append($0) }
    )
    #expect(values == [42])
    subscription.cancel()
  }

  @Test
  func ipcOverlayWritesReachPeers() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".sqlite"
    )
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: file.path + suffix)
      }
    }
    let network = SQLiteOrbit.InMemoryIPCTransport.Network()
    let first = OrbitIPCDatabase(
      writer: try SQLiteOrbit.SQLitePool(path: OrbitDatabasePath(file.path)),
      transport: SQLiteOrbit.InMemoryIPCTransport(network: network)
    )
    let second = OrbitIPCDatabase(
      writer: try SQLiteOrbit.SQLitePool(path: OrbitDatabasePath(file.path)),
      transport: SQLiteOrbit.InMemoryIPCTransport(network: network)
    )
    try await first.write { db in try db.execute(sql: "CREATE TABLE t(a INTEGER)") }
    var iterator = SQLiteOrbitGRDB.ValueObservation
      .tracking { db in
        try Int.fetchAll(db, sql: "SELECT a FROM t ORDER BY a")
      }
      .values(in: second).makeAsyncIterator()
    #expect(try await iterator.next() == [])
    try await first.write { db in try db.execute(sql: "INSERT INTO t VALUES (1)") }
    #expect(try await iterator.next() == [1])
  }

  @Test
  func codableFoundationAndJSON() throws {
    struct Document: Codable, FetchableRecord, PersistableRecord, Equatable {
      let id: UUID
      let createdAt: Date
      let data: Data
      let tags: [String]
      let optional: String?
    }

    let queue = try DatabaseQueue()
    let document = Document(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 123456),
      data: Data([0, 1, 255]),
      tags: ["a", "b"],
      optional: nil
    )
    try queue.write { db in
      try db.execute(
        sql:
          "CREATE TABLE document(id BLOB PRIMARY KEY, createdAt TEXT, data BLOB, tags TEXT, optional TEXT)"
      )
      try document.insert(db)
      #expect(try Document.fetchOne(db, id: document.id) == document)
      let row = try #require(try SQLiteOrbitGRDB.Row.fetchOne(db, sql: "SELECT * FROM document"))
      #expect(row["id"] as Data == document.id.databaseValue.storage.blobData)
      #expect(row["createdAt"] as String == "1970-01-02 10:17:36.000")
      #expect(row["tags"] as String == "[\"a\",\"b\"]")
    }
  }
}

extension SQLiteOrbitGRDB.DatabaseValue.Storage {
  fileprivate var blobData: Data? {
    if case .blob(let data) = self {
      data
    } else {
      nil
    }
  }
}
