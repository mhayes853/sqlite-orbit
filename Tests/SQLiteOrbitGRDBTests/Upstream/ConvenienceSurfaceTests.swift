// Shared application fixtures, run against both the overlay and GRDB 7.11.1.
import Foundation
import SQLiteOrbitGRDB
import XCTest

private struct ConveniencePlayer: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
  static let databaseTableName = "player"
  var id: Int64
  var name: String
  var score: Int
}

private enum DerivationError: Error { case expected }

class ConvenienceSurfaceTests: GRDBTestCase {
  private func makePlayers() throws -> DatabaseQueue {
    let database = try makeDatabaseQueue()
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TABLE player(id INTEGER PRIMARY KEY, name TEXT, score INTEGER);
          INSERT INTO player VALUES (3, 'C', 20), (1, 'a', 10), (2, 'B', 20);
          """
      )
    }
    return database
  }

  func testRequestArraysLiteralsAndAnnotations() throws {
    let database = try makePlayers()
    try database.read { db in
      let selection: [any SQLSelectable] = [Column("id"), Column("name")]
      let ordering: [any SQLOrderingTerm] = [Column("id").desc]
      let request = ConveniencePlayer.select(selection).order(ordering)
        .filter(literal: "score >= \(20)")
        .annotated(with: SQL(sql: "score + ? AS bonus", arguments: [5]))
        .annotated(with: SQL("\(Column("name")) || \("!") AS greeting"))
      let rows = try Row.fetchAll(db, request)
      XCTAssertEqual(rows.map { $0["id"] as Int }, [3, 2])
      XCTAssertEqual(rows.map { $0["bonus"] as Int }, [25, 25])
      XCTAssertEqual(rows.map { $0["greeting"] as String }, ["C!", "B!"])
      XCTAssertEqual(
        try ConveniencePlayer.select(literal: "name", as: String.self)
          .order(literal: "id").fetchAll(db),
        ["a", "B", "C"]
      )
      XCTAssertEqual(
        try Table<Int>("player").select(sql: "score", as: Int.self)
          .group(sql: "score").having(sql: "COUNT(*) > :n", arguments: ["n": 1])
          .fetchAll(db),
        [20]
      )
      XCTAssertEqual(
        try ConveniencePlayer.all().group([Column("score")]).having(literal: "COUNT(*) > \(1)")
          .select([Column("score")], as: Int.self).fetchAll(db),
        [20]
      )
      XCTAssertTrue(try ConveniencePlayer.all().none().isEmpty(db))
    }
  }

  func testDeferredPrimaryKeyDerivationsAndReplacement() throws {
    let request = ConveniencePlayer.selectPrimaryKey(as: Int64.self).orderByPrimaryKey().reversed()
    let database = try makePlayers()
    try database.read { db in
      XCTAssertEqual(try request.fetchAll(db), [3, 2, 1])
      XCTAssertEqual(try ConveniencePlayer.orderByPrimaryKey().selectID().fetchAll(db), [1, 2, 3])
      XCTAssertEqual(try request.select(sql: "name", as: String.self).fetchAll(db), ["C", "B", "a"])
      XCTAssertEqual(try request.order(Column("id")).fetchAll(db), [1, 2, 3])
      XCTAssertEqual(
        try ConveniencePlayer.selectPrimaryKey(as: Int.self)
          .annotated(with: [Column("score")]).asRequest(of: Row.self).fetchAll(db).first?
          .count,
        2
      )
      XCTAssertEqual(
        try ConveniencePlayer.all().groupByPrimaryKey().selectID().fetchSet(db),
        [1, 2, 3]
      )
      XCTAssertEqual(
        try Table<Int>("player").selectPrimaryKey(as: Int.self).orderByPrimaryKey()
          .reversed().limit(1).fetchOne(db),
        3
      )
    }
    try database.write { db in
      try db.execute(
        sql:
          "CREATE TABLE composite(a TEXT, b INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID; INSERT INTO composite VALUES ('x',2), ('x',1)"
      )
      let rows = try Table<Row>("composite").selectPrimaryKey(as: Row.self).orderByPrimaryKey()
        .fetchAll(db)
      XCTAssertEqual(rows.map { $0["b"] as Int }, [1, 2])
      XCTAssertEqual(Array(rows[0].columnNames), ["a", "b"])
      XCTAssertEqual(
        try ConveniencePlayer.all().group([any SQLExpressible]()).filter(id: 1)
          .updateAll(db, Column("score").set(to: 15)),
        1
      )
    }
  }

  func testConnectionDependentDerivationsPropagateErrors() throws {
    let database = try makePlayers()
    try database.read { db in
      let request = ConveniencePlayer.all()
        .filterWhenConnected { _ in Column("score") >= 10 }
        .selectWhenConnected { _ in [Column("name")] }
        .annotatedWhenConnected(with: { _ in [Column("score")] })
        .groupWhenConnected { _ in [Column("id")] }
        .havingWhenConnected { _ in count(Column("id")) > 0 }
        .orderWhenConnected { _ in [Column("id").desc] }
      XCTAssertEqual(try Row.fetchAll(db, request).map { $0["name"] as String }, ["C", "B", "a"])
      XCTAssertThrowsError(
        try ConveniencePlayer.all().filterWhenConnected { _ in throw DerivationError.expected }
          .fetchAll(db)
      )
      XCTAssertThrowsError(
        try ConveniencePlayer.all().havingWhenConnected { _ in throw DerivationError.expected }
          .fetchAll(db)
      )
      XCTAssertThrowsError(
        try ConveniencePlayer.all().selectWhenConnected { _ in throw DerivationError.expected }
          .fetchAll(db)
      )
      XCTAssertThrowsError(
        try ConveniencePlayer.all().orderWhenConnected { _ in throw DerivationError.expected }
          .fetchAll(db)
      )
      XCTAssertThrowsError(
        try ConveniencePlayer.all().groupWhenConnected { _ in throw DerivationError.expected }
          .fetchAll(db)
      )
    }
  }

  func testRecordChangeHelpersSkipUnchangedUpdates() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(
        sql:
          "CREATE TABLE audit(value); CREATE TRIGGER updated AFTER UPDATE ON player BEGIN INSERT INTO audit VALUES(1); END"
      )
      let original = try ConveniencePlayer.fetchOne(db, key: 1)!
      var player = original
      let changes = try player.databaseChanges { $0.score = 30 }
      XCTAssertEqual(changes, ["score": 10.databaseValue])
      XCTAssertTrue(try player.updateChanges(db, from: original))
      XCTAssertFalse(try player.updateChanges(db, from: player))
      XCTAssertNil(try player.updateChangesAndFetch(db) { $0.score = 30 })
      let fetched = try player.updateChangesAndFetch(db, as: ConveniencePlayer.self) {
        $0.score = 40
      }
      XCTAssertEqual(fetched?.score, 40)
      let score = try player.updateChangesAndFetch(
        db,
        selection: [Column("score")],
        fetch: { try Int.fetchOne($0) }
      ) { $0.score = 50 }
      XCTAssertEqual(score!, 50)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit"), 3)
      XCTAssertEqual(try ConveniencePlayer.fetchOne(db, key: 1)?.score, 50)
    }
  }

  func testGeneratedColumnsChecksDefaultsAndPartialIndexes() throws {
    let database = try makeDatabaseQueue()
    try database.write { db in
      try db.create(table: "item", options: .ifNotExists) { t in
        t.primaryKey("id", .integer)
        t.column("name", .text).collate(.nocase).indexed().check { length($0) > 0 }
        t.column("score", .integer).defaults(sql: "(5 + 5)")
        t.column("bonus", .integer).generatedAs(Column("score") + 1, .stored)
        t.check(Column("score") >= 0)
        t.constraint(literal: "CHECK (name <> \("forbidden'?") )")
      }
      // Indexed columns inherit IF NOT EXISTS from their table.
      try db.create(table: "item", options: .ifNotExists) { t in t.column("name", .text).indexed() }
      try db.create(
        indexOn: "item",
        columns: ["name", "score"],
        options: [.unique, .ifNotExists],
        condition: Column("score") > 10
      )
      try db.create(
        index: "expression_index",
        on: "item",
        expressions: [Column("score") + Column("bonus")]
      )
      try db.execute(sql: "INSERT INTO item(id,name) VALUES(1,'A'),(2,'a')")
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT bonus FROM item WHERE id=1"), 11)
      XCTAssertThrowsError(try db.execute(sql: "INSERT INTO item VALUES(3,'B',-1)"))
      try db.execute(sql: "INSERT INTO item(id,name,score) VALUES(3,'B',20)")
      XCTAssertThrowsError(try db.execute(sql: "INSERT INTO item(id,name,score) VALUES(4,'b',20)"))
      try db.alter(table: "item") { t in
        t.add(column: "doubled", .integer).generatedAs(sql: "score * 2")
      }
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT doubled FROM item WHERE id=3"), 40)
      XCTAssertTrue(try db.indexes(on: "item").contains { $0.name == "item_on_name" })
      try db.drop(indexOn: "ITEM", columns: ["NAME"])
      XCTAssertFalse(try db.indexes(on: "item").contains { $0.name == "item_on_name" })
    }
  }

  func testViewsQuoteValuesAndPreserveSQLText() throws {
    let database = try makePlayers()
    try database.write { db in
      let value = "O'Reilly ? :name — 🪐"
      let bytes = Data([0, 1, 255])
      try db.create(
        view: "quoted",
        asLiteral: "SELECT \(value) AS value, '?' AS marker, \(bytes) AS bytes /* ? */"
      )
      let row = try Row.fetchOne(db, sql: "SELECT * FROM quoted")!
      XCTAssertEqual(row["value"] as String, value)
      XCTAssertEqual(row["marker"] as String, "?")
      XCTAssertEqual(row["bytes"] as Data, bytes)
      try db.create(
        view: "highScores",
        options: [.temporary, .ifNotExists],
        columns: ["playerName"],
        as: Table<Row>("player").select(Column("name")).filter(Column("score") > 10)
      )
      XCTAssertEqual(try String.fetchSet(db, sql: "SELECT * FROM highScores"), ["B", "C"])
      try db.drop(view: "quoted")
      XCTAssertFalse(try db.viewExists("quoted"))
      // Identifier interpolation quotes punctuation and embedded quotes.
      let literal: SQL =
        "SELECT \(identifier: "name") FROM \(identifier: "player") ORDER BY \(identifier: "id")"
      XCTAssertEqual(try SQLRequest<String>(literal: literal).fetchAll(db), ["a", "B", "C"])
      XCTAssertEqual(
        try Table<String>("player").select(Column("name"), as: String.self)
          .order(Column("name").collating(.nocase)).fetchAll(db),
        ["a", "B", "C"]
      )
    }
  }

  func testSQLCompositionAndCachedLiterals() throws {
    let database = try makePlayers()
    try database.read { db in
      var sql: SQL = ""
      XCTAssertTrue(sql.isEmpty)
      sql.append(sql: "SELECT name FROM player WHERE score > ?", arguments: [10])
      sql += " ORDER BY id"
      let built = try sql.build(db)
      XCTAssertEqual(built.arguments, [10])
      XCTAssertEqual(
        try String.fetchAll(db, sql: built.sql, arguments: built.arguments),
        ["B", "C"]
      )
      let parts: [SQL] = ["SELECT \(1)", "SELECT \(2)"]
      let union = parts.joined(separator: " UNION ALL ")
      XCTAssertEqual(try SQLRequest<Int>(literal: union).fetchAll(db), [1, 2])
      let literal: SQL = "SELECT \(sql: "?", arguments: [42])"
      XCTAssertEqual(try Int.fetchOne(db.cachedStatement(literal: literal)), 42)
      let named: SQL =
        "SELECT \(sql: ":value + ?", arguments: StatementArguments(["value": 40]) + [2])"
      XCTAssertEqual(try Int.fetchOne(db.cachedStatement(literal: named)), 42)

    }
  }
  func testCursorCompositionPreservesCustomForEach() throws {
    XCTAssertEqual(
      try Dictionary(uniqueKeysWithValues: AnyCursor([3, 4]).enumerated()),
      [0: 3, 1: 4]
    )
    final class ForEachOnly: Cursor {
      func next() -> Int? { fatalError("Use the custom forEach") }
      func forEach(_ body: (Int) throws -> Void) throws {
        for value in [1, 2, 3] { try body(value) }
      }
    }
    XCTAssertEqual(try Array(ForEachOnly().compactMap { $0 == 2 ? nil : $0 }), [1, 3])
  }
}
