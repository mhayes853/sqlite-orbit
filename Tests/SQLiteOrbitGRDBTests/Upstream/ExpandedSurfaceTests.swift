// Shared application fixtures, run against both the overlay and GRDB 7.11.1.
import Foundation
import SQLiteOrbitGRDB
import XCTest

private struct UtilityPlayer: Codable, FetchableRecord, MutablePersistableRecord, Hashable,
  Identifiable
{
  static let databaseTableName = "player"
  var id: Int64?
  var name: String
  var score: Int

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

private struct PartialPlayer: Encodable, MutablePersistableRecord {
  static let databaseTableName = "player"
  var id: Int64?
  var name: String

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

private struct CompositeValue: Codable, FetchableRecord, PersistableRecord, Equatable {
  static let databaseTableName = "composite"
  var a: String
  var b: String
  var value: Int
}

private final class CallbackLog {
  var events: [String] = []
}

private struct CallbackPlayer: MutablePersistableRecord {
  static let databaseTableName = "player"
  var id: Int64?
  var name: String
  let log: CallbackLog

  func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id
    container["name"] = name
  }

  func willSave(_ db: Database) throws {
    log.events.append("willSave")
  }

  func aroundSave(_ db: Database, save: () throws -> PersistenceSuccess) throws {
    log.events.append("aroundSave.before")
    _ = try save()
    log.events.append("aroundSave.after")
  }

  func didSave(_ saved: PersistenceSuccess) {
    log.events.append("didSave")
  }

  mutating func willInsert(_ db: Database) throws {
    log.events.append("willInsert")
  }

  func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
    log.events.append("aroundInsert.before")
    _ = try insert()
    log.events.append("aroundInsert.after")
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
    log.events.append("didInsert")
  }

  func willUpdate(_ db: Database, columns: Set<String>) throws {
    log.events.append("willUpdate")
  }

  func aroundUpdate(_ db: Database, columns: Set<String>, update: () throws -> PersistenceSuccess)
    throws
  {
    log.events.append("aroundUpdate.before")
    _ = try update()
    log.events.append("aroundUpdate.after")
  }

  func didUpdate(_ updated: PersistenceSuccess) {
    log.events.append("didUpdate")
  }
}

class ExpandedSurfaceTests: GRDBTestCase {
  private func makePlayers() throws -> DatabaseQueue {
    let database = try makeDatabaseQueue()
    try database.write { db in
      try db.execute(
        sql:
          "CREATE TABLE player(id INTEGER PRIMARY KEY, name TEXT UNIQUE, score INTEGER DEFAULT 10)"
      )
    }
    return database
  }

  func testFetchSetsAndOverloadsOwnTheirRows() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(sql: "INSERT INTO player VALUES (1, 'A', 10), (2, 'B', 20), (3, 'C', 20)")
      XCTAssertEqual(try Int.fetchSet(db, sql: "SELECT score FROM player"), [10, 20])
      XCTAssertEqual(try Row.fetchSet(db, sql: "SELECT score FROM player").count, 2)
      XCTAssertEqual(try UtilityPlayer.all().fetchSet(db).count, 3)
      XCTAssertEqual(try UtilityPlayer.fetchSet(db, ids: [1, 3]).count, 2)
      XCTAssertEqual(try UtilityPlayer.find(db, key: ["name": "B"]).id, 2)
      XCTAssertEqual(try UtilityPlayer.fetchAll(db, keys: [["name": "A"], ["name": "C"]]).count, 2)
      XCTAssertEqual(try UtilityPlayer.fetchAll(db, keys: []).count, 0)
      let statement = try db.makeStatement(sql: "SELECT * FROM player ORDER BY id")
      XCTAssertEqual(try UtilityPlayer.fetchAll(statement).count, 3)
      XCTAssertEqual(try UtilityPlayer.fetchCursor(statement).next()?.name, "A")
      XCTAssertEqual(
        try Int.fetchSet(db, SQLRequest<Int>(sql: "SELECT score FROM player")),
        [10, 20]
      )
      XCTAssertTrue(try UtilityPlayer.filter(id: 99).isEmpty(db))
      XCTAssertFalse(try UtilityPlayer.exists(db, key: ["name": "absent"]))
      XCTAssertEqual(try UtilityPlayer.deleteAll(db, keys: [["name": "A"], ["name": "C"]]), 2)
      XCTAssertTrue(try UtilityPlayer.deleteOne(db, key: 2))
    }
  }

  func testRequestReversalAndExpressions() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(
        sql: "INSERT INTO player VALUES (1, 'Ada', 10), (2, 'Bob', 20), (3, 'Cat', 20)"
      )
      let request = UtilityPlayer.order(Column("score").desc, Column("id").asc)
      XCTAssertEqual(try request.fetchAll(db).compactMap(\.id), [2, 3, 1])
      XCTAssertEqual(try request.reversed().fetchAll(db).compactMap(\.id), [1, 3, 2])
      XCTAssertEqual(try request.reversed().reversed().fetchAll(db).compactMap(\.id), [2, 3, 1])
      XCTAssertEqual(try UtilityPlayer.all().reversed().fetchAll(db).compactMap(\.id), [1, 2, 3])
      XCTAssertEqual(
        try UtilityPlayer.filter((10..<20).contains(Column("score"))).fetchCount(db),
        1
      )
      XCTAssertEqual(
        try UtilityPlayer.filter((10...20).contains(Column("score"))).fetchCount(db),
        3
      )
      XCTAssertEqual(
        try Double.fetchOne(db, UtilityPlayer.select(average(Column("score")))),
        50.0 / 3
      )
      XCTAssertEqual(
        try Int.fetchOne(db, UtilityPlayer.select(sum(Column("score"), filter: Column("id") > 1))),
        40
      )
      XCTAssertEqual(
        try Int.fetchOne(db, UtilityPlayer.select(length(Column("name"))).filter(id: 1)),
        3
      )
      XCTAssertEqual(try request.unordered().fetchCount(db), 3)
    }
  }

  func testReturningUsesStatementValuesBeforeAfterTriggers() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER adjust AFTER INSERT ON player BEGIN UPDATE player SET score=99 WHERE id=new.id; END"
      )
      var player = PartialPlayer(name: "Alice")
      let returned = try player.insertAndFetch(db, as: UtilityPlayer.self)
      XCTAssertEqual(returned.score, 10)
      XCTAssertEqual(player.id, returned.id)
      XCTAssertEqual(try UtilityPlayer.find(db, id: returned.id!).score, 99)
      player.name = "Updated"
      let updated = try player.updateAndFetch(db, as: UtilityPlayer.self)
      XCTAssertEqual(updated.name, "Updated")
      var another = PartialPlayer(name: "Another")
      let score = try another.insertAndFetch(db, selection: [Column("score")]) {
        try Int.fetchOne($0)
      }
      XCTAssertEqual(score, 10)
      XCTAssertNotNil(another.id)
    }
  }

  func testReturningCallbacksSaveFallbackAndIgnoredConflicts() throws {
    let database = try makePlayers()
    try database.write { db in
      let log = CallbackLog()
      var player = CallbackPlayer(name: "Alice", log: log)
      let inserted = try player.insertAndFetch(db, as: UtilityPlayer.self)
      XCTAssertEqual(player.id, inserted.id)
      let insertEvents = [
        "willSave", "aroundSave.before", "willInsert", "aroundInsert.before", "aroundInsert.after",
        "didInsert", "aroundSave.after", "didSave"
      ]
      XCTAssertEqual(log.events, insertEvents)
      log.events = []
      player.name = "Changed"
      let saved = try player.saveAndFetch(db, as: UtilityPlayer.self)
      XCTAssertEqual(saved.name, "Changed")
      XCTAssertEqual(
        log.events,
        [
          "willSave", "aroundSave.before", "willUpdate", "aroundUpdate.before",
          "aroundUpdate.after", "didUpdate", "aroundSave.after", "didSave"
        ]
      )
      try db.execute(sql: "DELETE FROM player")
      log.events = []
      let fallback = try player.saveAndFetch(db, as: UtilityPlayer.self)
      XCTAssertEqual(fallback.id, player.id)
      XCTAssertEqual(
        log.events,
        [
          "willSave", "aroundSave.before", "willUpdate", "aroundUpdate.before", "willInsert",
          "aroundInsert.before", "aroundInsert.after", "didInsert", "aroundSave.after", "didSave"
        ]
      )
      var ignored = CallbackPlayer(name: "Changed", log: log)
      log.events = []
      XCTAssertThrowsError(
        try ignored.insertAndFetch(db, onConflict: .ignore, as: UtilityPlayer.self)
      )
      XCTAssertEqual(
        log.events,
        ["willSave", "aroundSave.before", "willInsert", "aroundInsert.before"]
      )
    }
  }

  func testUpsertReturnsConflictingRowIDAndUsesInsertCallbacks() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice', 10), (2, 'Bob', 20)")
      let log = CallbackLog()
      var player = CallbackPlayer(name: "Alice", log: log)
      try player.upsert(db)
      XCTAssertEqual(player.id, 1)
      XCTAssertEqual(try UtilityPlayer.fetchCount(db), 2)
      XCTAssertEqual(
        log.events,
        [
          "willSave", "aroundSave.before", "willInsert", "aroundInsert.before",
          "aroundInsert.after", "didInsert", "aroundSave.after", "didSave"
        ]
      )
      var incoming = UtilityPlayer(name: "Alice", score: 5)
      let merged = try incoming.upsertAndFetch(
        db,
        onConflict: ["name"],
        updating: .noColumnUnlessSpecified
      ) { excluded in
        [Column("score").set(to: Column("score") + excluded[Column("score")])]
      }
      XCTAssertEqual(merged.id, 1)
      XCTAssertEqual(incoming.id, 1)
      XCTAssertEqual(merged.score, 15)
      let immutable = CompositeValue(a: "a", b: "b", value: 1)
      try db.execute(
        sql: "CREATE TABLE composite(a TEXT, b TEXT, value INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID"
      )
      try immutable.upsert(db)
      XCTAssertEqual(try CompositeValue(a: "a", b: "b", value: 2).upsertAndFetch(db).value, 2)
    }
  }

  func testSchemaInspectionResolvesSchemasIndexesAndForeignKeys() throws {
    let database = try makeDatabaseQueue()
    try database.write { db in
      let version = try db.schemaVersion()
      try db.execute(
        sql: """
          CREATE TABLE parent(a TEXT, b TEXT, PRIMARY KEY(a,b));
          CREATE TABLE child(x TEXT, y TEXT, FOREIGN KEY(x,y) REFERENCES parent);
          CREATE UNIQUE INDEX child_xy ON child(x,y);
          CREATE INDEX child_expression ON child(lower(x));
          CREATE VIEW child_view AS SELECT x FROM child;
          CREATE TEMP TABLE child(temp_value);
          ATTACH DATABASE ':memory:' AS extra;
          CREATE TABLE extra.child(extra_value);
          """
      )
      XCTAssertGreaterThan(try db.schemaVersion(), version)
      XCTAssertEqual(try db.columns(in: "child").map(\.name), ["temp_value"])
      XCTAssertEqual(try db.columns(in: "child", in: "extra").map(\.name), ["extra_value"])
      XCTAssertTrue(try db.viewExists("child_view"))
      XCTAssertTrue(try db.tableExists("child", in: "MAIN"))
      let indexes = try db.indexes(on: "child", in: "main")
      XCTAssertEqual(indexes.map(\.name), ["child_xy"])
      XCTAssertEqual(indexes[0].columns, ["x", "y"])
      XCTAssertTrue(indexes[0].isUnique)
      XCTAssertEqual(indexes[0].origin, .createIndex)
      let foreignKeys = try db.foreignKeys(on: "child", in: "main")
      XCTAssertEqual(foreignKeys[0].originColumns, ["x", "y"])
      XCTAssertEqual(foreignKeys[0].destinationColumns, ["a", "b"])
      XCTAssertThrowsError(try db.columns(in: "missing"))
      XCTAssertThrowsError(try db.indexes(on: "child", in: "unknown"))
    }
  }

  func testAggregateStateIsSeparateForGroupsAndEmptyInput() throws {
    struct Sum: DatabaseAggregate {
      var value = 0

      init() {}

      mutating func step(_ values: [DatabaseValue]) throws {
        value += Int.fromDatabaseValue(values[0]) ?? 0
      }

      func finalize() throws -> (any DatabaseValueConvertible)? {
        value
      }
    }

    var configuration = Configuration()
    let function = DatabaseFunction("customSum", argumentCount: 1, pure: true, aggregate: Sum.self)
    configuration.prepareDatabase { $0.add(function: function) }
    let database = try DatabaseQueue(configuration: configuration)
    try database.write { db in
      try db.execute(
        sql: "CREATE TABLE item(g, v); INSERT INTO item VALUES (1, 2), (1, NULL), (2, 7)"
      )
      XCTAssertEqual(
        try Int.fetchAll(db, sql: "SELECT customSum(v) FROM item GROUP BY g ORDER BY g"),
        [2, 7]
      )
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT customSum(v) FROM item WHERE 0"), 0)
      XCTAssertEqual(
        try Int.fetchOne(db, Table<Row>("item").all().select(function(Column("v")))),
        9
      )
    }
  }

  func testCheckpointModeMappingAndCounts() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let database = try DatabaseQueue(path: path)
    try database.writeWithoutTransaction { db in
      try db.execute(
        sql: "PRAGMA journal_mode=WAL; CREATE TABLE item(id); INSERT INTO item VALUES (1)"
      )
      let passive = try db.checkpoint()
      XCTAssertGreaterThanOrEqual(passive.walFrameCount, 0)
      XCTAssertEqual(passive.walFrameCount, passive.checkpointedFrameCount)
      _ = try db.checkpoint(.full)
      _ = try db.checkpoint(.restart)
      let truncated = try db.checkpoint(.truncate, on: "main")
      XCTAssertEqual(truncated.walFrameCount, 0)
      XCTAssertEqual(truncated.checkpointedFrameCount, 0)
    }
  }

  func testPartialReturningUpdatesAndGeneratedColumns() throws {
    struct Generated: Codable, FetchableRecord, PersistableRecord {
      static let databaseTableName = "generated"
      let id: Int
      let name: String
      let upperName: String
    }

    let database = try makePlayers()
    try database.write { db in
      var player = UtilityPlayer(name: "Alice", score: 10)
      try player.insert(db)
      player.name = "Changed"
      player.score = 99
      let updated = try player.updateAndFetch(
        db,
        columns: [Column("name")],
        selection: UtilityPlayer.databaseSelection
      ) {
        try UtilityPlayer.fetchOne($0)!
      }
      XCTAssertEqual(updated.name, "Changed")
      XCTAssertEqual(updated.score, 10)
      let selected = try player.updateAndFetch(db, columns: ["score"], selection: [Column("score")])
      { try Int.fetchOne($0) }
      XCTAssertEqual(selected, 99)
      try db.execute(
        sql:
          "CREATE TABLE generated(id INTEGER PRIMARY KEY, name TEXT, upperName TEXT GENERATED ALWAYS AS (upper(name)) STORED)"
      )
      XCTAssertEqual(try db.columns(in: "generated").map(\.name), ["id", "name", "upperName"])
      try db.execute(sql: "INSERT INTO generated(id, name) VALUES (1, 'hello')")
      XCTAssertEqual(try Generated.find(db, key: 1).upperName, "HELLO")
      XCTAssertTrue(try db.table("generated", hasUniqueKey: ["rowid"]))
      XCTAssertTrue(try db.table("generated", hasUniqueKey: ["id", "name"]))
      XCTAssertFalse(try db.table("generated", hasUniqueKey: ["name"]))
      XCTAssertFalse(try db.table("missing", hasUniqueKey: []))
    }
  }

  func testReturningIgnoreAndAbsentUpdateFailures() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(sql: "INSERT INTO player VALUES (1, 'A', 10), (2, 'B', 20)")
      let conflict = UtilityPlayer(id: 1, name: "B", score: 100)
      XCTAssertThrowsError(try conflict.updateAndFetch(db, onConflict: .ignore))
      XCTAssertEqual(try UtilityPlayer.find(db, key: 1).name, "A")
      let absent = UtilityPlayer(id: 99, name: "C", score: 30)
      XCTAssertThrowsError(try absent.updateAndFetch(db))
      try db.execute(sql: "CREATE TABLE counter(value)")
      // GRDB reads the connection's change count after the custom fetch closure returns.
      let result = try absent.updateAndFetch(db, selection: [Column("id")]) { statement in
        let value = try Int.fetchOne(statement)
        try db.execute(sql: "INSERT INTO counter VALUES (1)")
        return value
      }
      XCTAssertNil(result)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM counter"), 1)
      var ignored = PartialPlayer(name: "B")
      let optional = try ignored.insertAndFetch(
        db,
        onConflict: .ignore,
        selection: [Column("score")]
      ) { try Int.fetchOne($0) }
      XCTAssertNil(optional)
      XCTAssertEqual(try UtilityPlayer.fetchCount(db), 2)
    }
  }

  func testAggregateErrorsPropagateAndPoolConnectionsArePrepared() throws {
    enum Failure: Error {
      case rejected
    }

    struct RejectNegative: DatabaseAggregate {
      var sum = 0

      init() {}

      mutating func step(_ values: [DatabaseValue]) throws {
        let value = Int.fromDatabaseValue(values[0]) ?? 0
        if value < 0 {
          throw Failure.rejected
        }
        sum += value
      }

      func finalize() throws -> (any DatabaseValueConvertible)? {
        sum
      }
    }

    var configuration = Configuration()
    configuration.maximumReaderCount = 2
    configuration.prepareDatabase {
      $0.add(
        function: DatabaseFunction(
          "rejectNegative",
          argumentCount: 1,
          aggregate: RejectNegative.self
        )
      )
    }
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let database = try DatabasePool(path: path, configuration: configuration)
    for _ in 0..<4 {
      XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT rejectNegative(2)") }, 2)
    }
    try database.write { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rejectNegative(3)"), 3)
      XCTAssertThrowsError(try Int.fetchOne(db, sql: "SELECT rejectNegative(-1)"))
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rejectNegative(4)"), 4)
    }
  }

  func testUpsertDefaultsAndExplicitUpdateStrategy() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice', 10)")
      var incoming = UtilityPlayer(name: "Alice", score: 100)
      let kept = try incoming.upsertAndFetch(
        db,
        onConflict: ["name"],
        updating: .noColumnUnlessSpecified
      )
      XCTAssertEqual(kept.score, 10)
      XCTAssertEqual(incoming.id, 1)
      var new = PartialPlayer(name: "New")
      let inserted = try new.upsertAndFetch(db, as: UtilityPlayer.self)
      XCTAssertEqual(inserted.score, 10)
      XCTAssertEqual(new.id, inserted.id)
      XCTAssertEqual(try UtilityPlayer.fetchCount(db), 2)
    }
  }

}
