// swift-format-ignore-file: NoAssignmentInExpressions

// GRDB compound column operators return SQL assignments without mutating their operands.
// Shared application fixtures, run against both the overlay and GRDB 7.11.1.
// Reference scenarios: TableRecordUpdateTests and TableRecordDeleteTests.
import Foundation
import SQLiteOrbitGRDB
import XCTest

private struct BulkPlayer: Codable, FetchableRecord, PersistableRecord, Hashable, Identifiable {
  static let databaseTableName = "bulk_player"
  var id: Int64
  var name: String
  var score: Int
  var bonus: Int

  func willUpdate(_ db: Database, columns: Set<String>) throws {
    XCTFail("Bulk updates must not invoke per-record callbacks")
  }
  func willDelete(_ db: Database) throws {
    XCTFail("Bulk deletes must not invoke per-record callbacks")
  }
}

private struct IgnoringBulkPlayer: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "bulk_player"
  static let persistenceConflictPolicy = PersistenceConflictPolicy(update: .ignore)
  var id: Int64
  var name: String
  var score: Int
  var bonus: Int
}

private enum BulkDecodeFailure: Error { case expected }
private struct UndecodableBulkPlayer: FetchableRecord, TableRecord {
  static let databaseTableName = "bulk_player"
  init(row: Row) throws { throw BulkDecodeFailure.expected }
}

class BulkPersistenceTests: GRDBTestCase {
  private func makePlayers() throws -> DatabaseQueue {
    let database = try makeDatabaseQueue()
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TABLE bulk_player(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, score INTEGER NOT NULL, bonus INTEGER NOT NULL);
          INSERT INTO bulk_player VALUES(1,'Arthur',10,2),(2,'Barbara',20,1),(3,'Craig',30,0);
          """
      )
    }
    return database
  }

  func testBulkUpdateOverloadsCountsAndEmptyAssignments() throws {
    let database = try makePlayers()
    try database.write { db in
      XCTAssertEqual(try BulkPlayer.updateAll(db, []), 0)
      XCTAssertEqual(try Table<Row>("missing").all().updateAll(db, []), 0)
      XCTAssertEqual(try BulkPlayer.updateAll(db, Column("score") += 1), 3)
      XCTAssertEqual(try BulkPlayer.filter(key: 1).updateAll(db, [Column("score") += 2]), 1)
      XCTAssertEqual(try BulkPlayer.filter(key: 99).updateAll(db, Column("score").set(to: 0)), 0)
      XCTAssertEqual(
        try BulkPlayer.filter(Column("bonus") > 0)
          .updateAll(db, [Column("score") += Column("bonus")]),
        2
      )
      XCTAssertEqual(
        try Int.fetchAll(db, sql: "SELECT score FROM bulk_player ORDER BY id"),
        [15, 22, 31]
      )
      XCTAssertEqual(
        try BulkPlayer.updateAll(db, onConflict: .abort, [Column("bonus").set(to: 5)]),
        3
      )
      XCTAssertEqual(try BulkPlayer.updateAll(db, onConflict: .abort, Column("bonus") -= 1), 3)
    }
  }

  func testCompoundAssignmentsUseTheOriginalRowValues() throws {
    let database = try makePlayers()
    try database.write { db in
      let request = BulkPlayer.filter(key: 1)
      try request.updateAll(
        db,
        [Column("score") += Column("bonus"), Column("bonus").set(to: Column("score"))]
      )
      XCTAssertEqual(try BulkPlayer.fetchOne(db, key: 1)?.score, 12)
      XCTAssertEqual(try BulkPlayer.fetchOne(db, key: 1)?.bonus, 10)
      try request.updateAll(db, Column("score") *= 2)
      try request.updateAll(db, Column("score") /= 3)
      try request.updateAll(db, Column("score") |= 3)
      try request.updateAll(db, Column("score") &= 7)
      try request.updateAll(db, Column("score") <<= 2)
      try request.updateAll(db, Column("score") >>= 1)
      XCTAssertEqual(try BulkPlayer.fetchOne(db, key: 1)?.score, 6)
    }
  }

  func testConflictDefaultsAndExplicitOverrides() throws {
    let database = try makePlayers()
    try database.write { db in
      XCTAssertEqual(
        try IgnoringBulkPlayer.filter(key: 1).updateAll(db, Column("name").set(to: "Barbara")),
        0
      )
      XCTAssertTrue(
        try IgnoringBulkPlayer.filter(key: 1)
          .updateAndFetchAll(db, [Column("name").set(to: "Barbara")]).isEmpty
      )
      XCTAssertThrowsError(
        try IgnoringBulkPlayer.filter(key: 1)
          .updateAll(db, onConflict: .abort, Column("name").set(to: "Barbara"))
      )
      XCTAssertThrowsError(
        try IgnoringBulkPlayer.filter(key: 1)
          .updateAndFetchAll(db, onConflict: .abort, [Column("name").set(to: "Barbara")])
      )
      let replaced = try BulkPlayer.filter(key: 1)
        .updateAndFetchAll(db, onConflict: .replace, [Column("name").set(to: "Barbara")])
      XCTAssertEqual(replaced.map(\.id), [1])
      XCTAssertEqual(try BulkPlayer.fetchCount(db), 2)
      XCTAssertNil(try BulkPlayer.fetchOne(db, key: 2))
    }
  }

  func testUpdateReturningUsesDatabaseSelectionAndReturnsAllAndSet() throws {
    let database = try makePlayers()
    try database.write { db in
      let updated = try BulkPlayer.filter(Column("id") != 2).select(Column("id"))
        .updateAndFetchAll(db, [Column("score") += 100]).sorted { $0.id < $1.id }
      XCTAssertEqual(
        updated,
        [
          BulkPlayer(id: 1, name: "Arthur", score: 110, bonus: 2),
          BulkPlayer(id: 3, name: "Craig", score: 130, bonus: 0)
        ]
      )
      let set = try BulkPlayer.filter(key: 2).updateAndFetchSet(db, [Column("bonus").set(to: 9)])
      XCTAssertEqual(set, [BulkPlayer(id: 2, name: "Barbara", score: 20, bonus: 9)])
      XCTAssertTrue(
        try BulkPlayer.filter(key: 99).updateAndFetchAll(db, [Column("score") += 1]).isEmpty
      )
    }
  }

  func testReturningStatementsDoNotExecuteUntilSteppedAndAllowCustomSelections() throws {
    let database = try makePlayers()
    try database.write { db in
      let statement = try BulkPlayer.filter(key: 1)
        .updateAndFetchStatement(
          db,
          [Column("score") += 5],
          selection: [Column("id"), (Column("score") + 2).forKey("adjusted")]
        )
      XCTAssertEqual(try BulkPlayer.fetchOne(db, key: 1)?.score, 10)
      XCTAssertEqual(statement.columnNames, ["id", "adjusted"])
      let rows = try Row.fetchAll(statement)
      XCTAssertEqual(rows[0]["id"] as Int, 1)
      XCTAssertEqual(rows[0]["adjusted"] as Int, 17)
      let deleted = try BulkPlayer.filter(key: 1)
        .deleteAndFetchStatement(db, selection: [Column("name")])
      XCTAssertTrue(try BulkPlayer.exists(db, key: 1))
      XCTAssertEqual(try String.fetchAll(deleted), ["Arthur"])
      XCTAssertFalse(try BulkPlayer.exists(db, key: 1))
    }
  }

  func testDeleteReturningAllSetAndIds() throws {
    let database = try makePlayers()
    try database.write { db in
      let deleted = try BulkPlayer.filter(key: 2).deleteAndFetchAll(db)
      XCTAssertEqual(deleted, [BulkPlayer(id: 2, name: "Barbara", score: 20, bonus: 1)])
      let set = try BulkPlayer.filter(key: 3).deleteAndFetchSet(db)
      XCTAssertEqual(set, [BulkPlayer(id: 3, name: "Craig", score: 30, bonus: 0)])
      XCTAssertEqual(try BulkPlayer.all().deleteAndFetchIds(db), [1])
      XCTAssertTrue(try BulkPlayer.all().deleteAndFetchIds(db).isEmpty)
    }
  }

  func testUnusedCursorsDoNotMutateAndFirstStepMutatesEveryMatchingRow() throws {
    let database = try makePlayers()
    try database.write { db in
      do {
        let cursor = try BulkPlayer.all().updateAndFetchCursor(db, [Column("score") += 100])
        withExtendedLifetime(cursor) {
          XCTAssertEqual(try? Int.fetchOne(db, sql: "SELECT SUM(score) FROM bulk_player"), 60)
        }
      }
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(score) FROM bulk_player"), 60)
      do {
        let cursor = try BulkPlayer.all().updateAndFetchCursor(db, [Column("score") += 1])
        XCTAssertNotNil(try cursor.next())
      }
      XCTAssertEqual(
        try Int.fetchAll(db, sql: "SELECT score FROM bulk_player ORDER BY id"),
        [11, 21, 31]
      )
      do {
        let cursor = try BulkPlayer.all().deleteAndFetchCursor(db)
        XCTAssertNotNil(try cursor.next())
      }
      XCTAssertEqual(try BulkPlayer.fetchCount(db), 0)
    }
  }

  func testDecodingFailuresLeaveStatementChangesInTheTransaction() throws {
    let database = try makePlayers()
    try database.write { db in
      do {
        _ = try UndecodableBulkPlayer.all().updateAndFetchAll(db, [Column("score") += 1])
        XCTFail("Expected decoding failure")
      } catch { XCTAssertTrue(error is BulkDecodeFailure) }
      XCTAssertEqual(
        try Int.fetchAll(db, sql: "SELECT score FROM bulk_player ORDER BY id"),
        [11, 21, 31]
      )
      do {
        _ = try UndecodableBulkPlayer.filter(key: 1).deleteAndFetchAll(db)
        XCTFail("Expected decoding failure")
      } catch { XCTAssertTrue(error is BulkDecodeFailure) }
      XCTAssertEqual(try BulkPlayer.fetchCount(db), 2)
    }
    XCTAssertThrowsError(
      try database.write { db in
        _ = try UndecodableBulkPlayer.all().updateAndFetchAll(db, [Column("score") += 100])
      }
    )
    XCTAssertEqual(
      try database.read { try Int.fetchAll($0, sql: "SELECT score FROM bulk_player ORDER BY id") },
      [21, 31]
    )
  }

  func testReturningValuesPrecedeAfterTriggersAndIncludeGeneratedColumns() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(
        sql: """
          ALTER TABLE bulk_player ADD COLUMN doubled INTEGER GENERATED ALWAYS AS (score * 2) VIRTUAL;
          CREATE TRIGGER bumped AFTER UPDATE OF score ON bulk_player BEGIN
            UPDATE bulk_player SET bonus=999 WHERE id=NEW.id;
          END;
          """
      )
      let statement = try BulkPlayer.filter(key: 1)
        .updateAndFetchStatement(
          db,
          [Column("score") += 1],
          selection: [Column("score"), Column("bonus"), Column("doubled")]
        )
      let row = try XCTUnwrap(Row.fetchAll(statement).first)
      XCTAssertEqual(row["score"] as Int, 11)
      XCTAssertEqual(row["bonus"] as Int, 2)
      XCTAssertEqual(row["doubled"] as Int, 22)
      XCTAssertEqual(try BulkPlayer.fetchOne(db, key: 1)?.bonus, 999)
    }
  }

  func testUnlimitedMutationIgnoresOrderingWithoutResolvingIt() throws {
    let database = try makePlayers()
    try database.write { db in
      let request = BulkPlayer.all().orderWhenConnected { _ in throw BulkDecodeFailure.expected }
      XCTAssertEqual(try request.updateAll(db, Column("score") += 1), 3)
      XCTAssertEqual(try request.updateAndFetchAll(db, [Column("score") += 1]).count, 3)
      XCTAssertEqual(try request.deleteAndFetchAll(db).count, 3)
    }
  }

  func testUniqueKeyGroupingAndHavingUseSelectedRowIdentities() throws {
    let database = try makePlayers()
    try database.write { db in
      let updated = try BulkPlayer.all().groupByPrimaryKey().having(Column("score") > 10)
        .order(Column("id").desc).limit(1).updateAndFetchAll(db, [Column("score") += 100])
      XCTAssertEqual(updated.map(\.id), [3])
      XCTAssertEqual(
        try BulkPlayer.all().group(-Column("id")).having(Column("id") == 2).deleteAll(db),
        1
      )
      XCTAssertEqual(
        try BulkPlayer.all().group([Column("name")]).having(Column("id") == 1)
          .deleteAndFetchIds(db),
        [1]
      )
      XCTAssertEqual(try BulkPlayer.fetchAll(db).map(\.id), [3])
    }
  }

  func testViewsCountTriggerChangesAndSupportExplicitReturningSelections() throws {
    let database = try makePlayers()
    try database.write { db in
      try db.execute(
        sql: """
          CREATE VIEW player_view AS SELECT * FROM bulk_player;
          CREATE TRIGGER update_view INSTEAD OF UPDATE ON player_view BEGIN
            UPDATE bulk_player SET score=NEW.score WHERE id=OLD.id;
          END;
          CREATE TRIGGER delete_view INSTEAD OF DELETE ON player_view BEGIN
            DELETE FROM bulk_player WHERE id=OLD.id;
          END;
          """
      )
      let request = Table<Row>("player_view").all()
      XCTAssertEqual(try request.filter(Column("id") == 1).updateAll(db, Column("score") += 10), 1)
      let statement = try request.filter(Column("id") == 2)
        .updateAndFetchStatement(db, [Column("score") += 10], selection: [Column("score")])
      XCTAssertEqual(try Int.fetchAll(statement), [30])
      XCTAssertEqual(try request.filter(Column("id") == 1).deleteAll(db), 1)
    }
  }

  func testLimitedReturningMatchesTheSelectedEngineGrammar() throws {
    let database = try makePlayers()
    try database.write { db in
      let supported =
        (try? db.makeStatement(sql: "UPDATE bulk_player SET score=0 LIMIT 1 RETURNING id")) != nil
      let request = BulkPlayer.all().order(Column("id")).limit(1)
      if supported {
        XCTAssertEqual(try request.updateAndFetchAll(db, [Column("score").set(to: 0)]).count, 1)
        XCTAssertEqual(try request.deleteAndFetchAll(db).count, 1)
      } else {
        XCTAssertThrowsError(try request.updateAndFetchAll(db, [Column("score").set(to: 0)]))
        XCTAssertThrowsError(try request.deleteAndFetchAll(db))
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(score) FROM bulk_player"), 60)
      }
    }
  }
  func testIgnoredConflictsReturnOnlyWrittenRows() throws {
    let database = try makePlayers()
    try database.write { db in
      let updated = try BulkPlayer.all()
        .updateAndFetchAll(
          db,
          onConflict: .ignore,
          [
            Column("name").set(to: "Barbara"), Column("score") += 100
          ]
        )
      XCTAssertEqual(updated.map(\.id), [2])
      XCTAssertEqual(
        try Int.fetchAll(db, sql: "SELECT score FROM bulk_player ORDER BY id"),
        [10, 120, 30]
      )
    }
  }

  func testFailConflictRetainsEarlierStatementChangesWhenCaught() throws {
    let database = try makePlayers()
    try database.write { db in
      do {
        _ = try BulkPlayer.updateAll(db, onConflict: .fail, Column("name").set(to: "same"))
        XCTFail("Expected uniqueness failure")
      } catch let error as DatabaseError { XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT) }
      XCTAssertEqual(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bulk_player WHERE name='same'"),
        1
      )
    }
  }

  func testVirtualTableCountsAndReturningRejection() throws {
    let database = try makeDatabaseQueue()
    try database.write { db in
      do { try db.execute(sql: "CREATE VIRTUAL TABLE document USING fts5(content)") } catch {
        throw XCTSkip("FTS5 is unavailable")
      }
      try db.execute(sql: "INSERT INTO document(content) VALUES ('one'), ('two')")
      let request = Table<Row>("document").all()
      XCTAssertEqual(
        try request.filter(sql: "rowid < 0").updateAll(db, Column("content").set(to: "none")),
        0
      )
      XCTAssertEqual(
        try request.filter(sql: "rowid = 1").updateAll(db, Column("content").set(to: "updated")),
        1
      )
      XCTAssertThrowsError(
        try request.updateAndFetchStatement(
          db,
          [Column("content").set(to: "invalid")],
          selection: [Column("content")]
        )
      )
      XCTAssertThrowsError(try request.deleteAndFetchStatement(db, selection: [Column("content")]))
      XCTAssertEqual(
        try String.fetchAll(db, sql: "SELECT content FROM document ORDER BY rowid"),
        ["updated", "two"]
      )
      XCTAssertEqual(try request.deleteAll(db), 2)
    }
  }

}
