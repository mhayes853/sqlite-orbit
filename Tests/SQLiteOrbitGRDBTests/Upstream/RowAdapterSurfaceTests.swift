// Shared application fixtures, run against the overlay and GRDB 7.11.1.
import Foundation
import SQLiteOrbitGRDB
import XCTest

private struct AdapterPlayer: Codable, FetchableRecord, Hashable {
  var id: Int
  var name: String
}

private struct AdapterJoined: Decodable, FetchableRecord, Equatable {
  var player: AdapterPlayer
  var team: AdapterPlayer?
}

private struct AdapterPlainPlayer: Decodable, Equatable {
  var id: Int
  var name: String
}

private struct AdapterPlainJoined: Decodable, FetchableRecord, Equatable {
  var player: AdapterPlainPlayer
  var team: AdapterPlainPlayer?
}

private struct AdapterManualRecord: Decodable, FetchableRecord, Equatable {
  var name: String
  init(row: Row) throws { name = "custom:" + (try row.decode(String.self, forColumn: "name")) }
}

private struct AdapterManualJoined: Decodable, FetchableRecord {
  var player: AdapterManualRecord
}

private struct PrefixedColumnsAdapter: RowAdapter {
  let prefix: String
  func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
    var mapping: [String: String] = [:]
    for (_, name) in layout._layoutColumns where name.hasPrefix(prefix) {
      mapping[String(name.dropFirst(prefix.count))] = name
    }
    return try ColumnMapping(mapping)._layoutedAdapter(from: layout)
  }
}

private struct AdapterInspectingRecord: Decodable, FetchableRecord {
  let keys: Set<String>
  let name: String
  enum CodingKeys: String, CodingKey { case player, team, missing }
  enum PlayerKeys: String, CodingKey { case id, name }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    keys = Set(container.allKeys.map(\.stringValue))
    XCTAssertTrue(container.contains(.player))
    XCTAssertTrue(container.contains(.team))
    XCTAssertFalse(container.contains(.missing))
    XCTAssertTrue(try container.decodeNil(forKey: .team))
    let player = try container.nestedContainer(keyedBy: PlayerKeys.self, forKey: .player)
    name = try player.decode(String.self, forKey: .name)
  }
}

private struct AdapterCodedPlayer: Decodable, FetchableRecord {
  static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
  let firstName: String
}

private struct AdapterCodedJoined: Decodable, FetchableRecord {
  static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
  let thePlayer: AdapterCodedPlayer
}

private struct AdapterPlainSnakePlayer: Decodable {
  let firstName: String
  enum CodingKeys: String, CodingKey { case firstName = "first_name" }
}

private struct AdapterPlainSnakeJoined: Decodable, FetchableRecord {
  static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
  let player: AdapterPlainSnakePlayer
}

private enum AdapterExpectedError: Error { case expected }
private struct ThrowingRowAdapter: RowAdapter {
  func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
    throw AdapterExpectedError.expected
  }
}

class RowAdapterSurfaceTests: GRDBTestCase {
  private let playersSQL =
    "SELECT 99 AS extra, 1 AS id, 'Arthur' AS name UNION ALL SELECT 98, 2, 'Barbara'"

  private func joinedAdapter() -> ScopeAdapter {
    ScopeAdapter(
      base: EmptyRowAdapter(),
      scopes: [
        "player": RangeRowAdapter(0..<2),
        "team": RangeRowAdapter(2..<4)
      ]
    )
  }

  func testRowFetchingFamiliesUseAdaptedColumns() throws {
    try makeDatabaseQueue()
      .read { db in
        let adapter = SuffixRowAdapter(fromIndex: 1)
        let statement = try db.makeStatement(sql: playersSQL)
        let request = SQLRequest<Void>(sql: playersSQL, adapter: adapter, cached: true)
        let expected: [Row] = [["id": 1, "name": "Arthur"], ["id": 2, "name": "Barbara"]]
        XCTAssertEqual(try Row.fetchAll(db, sql: playersSQL, adapter: adapter), expected)
        XCTAssertEqual(try Row.fetchAll(statement, adapter: adapter), expected)
        XCTAssertEqual(try Row.fetchAll(db, request), expected)
        XCTAssertEqual(try Row.fetchOne(statement, adapter: adapter), expected[0])
        XCTAssertEqual(try Row.fetchOne(db, request), expected[0])
        XCTAssertEqual(try Row.fetchSet(db, sql: playersSQL, adapter: adapter), Set(expected))
        XCTAssertEqual(try Row.fetchSet(statement, adapter: adapter), Set(expected))
        XCTAssertEqual(try Row.fetchSet(db, request), Set(expected))
        XCTAssertEqual(try Array(Row.fetchCursor(db, request).map { $0.copy() }), expected)
      }
  }

  func testScalarFetchingFamiliesUseFirstAdaptedColumn() throws {
    try makeDatabaseQueue()
      .read { db in
        let adapter = RangeRowAdapter(1...1)
        let statement = try db.makeStatement(sql: playersSQL)
        let request = SQLRequest<Int>(sql: playersSQL, adapter: adapter, cached: true)
        XCTAssertEqual(try Int.fetchAll(db, sql: playersSQL, adapter: adapter), [1, 2])
        XCTAssertEqual(try Int.fetchOne(db, sql: playersSQL, adapter: adapter), 1)
        XCTAssertEqual(try Array(Int.fetchCursor(db, sql: playersSQL, adapter: adapter)), [1, 2])
        XCTAssertEqual(try Int.fetchSet(db, sql: playersSQL, adapter: adapter), [1, 2])
        XCTAssertEqual(try Int.fetchAll(statement, adapter: adapter), [1, 2])
        XCTAssertEqual(try Int.fetchOne(statement, adapter: adapter), 1)
        XCTAssertEqual(try Array(Int.fetchCursor(statement, adapter: adapter)), [1, 2])
        XCTAssertEqual(try Int.fetchSet(statement, adapter: adapter), [1, 2])
        XCTAssertEqual(try Int.fetchAll(db, request), [1, 2])
        XCTAssertEqual(try Int.fetchOne(db, request), 1)
        XCTAssertEqual(try Array(Int.fetchCursor(db, request)), [1, 2])
        XCTAssertEqual(try Int.fetchSet(db, request), [1, 2])
        XCTAssertEqual(try request.fetchAll(db), [1, 2])
        XCTAssertEqual(try request.fetchOne(db), 1)
        XCTAssertEqual(try Array(request.fetchCursor(db)), [1, 2])
        XCTAssertEqual(try request.fetchSet(db), [1, 2])
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT 99, NULL", adapter: adapter), nil)
        let nullRequest = SQLRequest<Int?>(sql: "SELECT 99, NULL", adapter: adapter)
        XCTAssertEqual(try nullRequest.fetchAll(db), [nil])
      }
  }

  func testRecordFetchingFamiliesUseAdaptedRows() throws {
    try makeDatabaseQueue()
      .read { db in
        let adapter = SuffixRowAdapter(fromIndex: 1)
        let statement = try db.makeStatement(sql: playersSQL)
        let request = SQLRequest<AdapterPlayer>(sql: playersSQL, adapter: adapter)
        let expected = [AdapterPlayer(id: 1, name: "Arthur"), AdapterPlayer(id: 2, name: "Barbara")]
        XCTAssertEqual(try AdapterPlayer.fetchAll(db, sql: playersSQL, adapter: adapter), expected)
        XCTAssertEqual(
          try AdapterPlayer.fetchOne(db, sql: playersSQL, adapter: adapter),
          expected[0]
        )
        XCTAssertEqual(
          try Array(AdapterPlayer.fetchCursor(db, sql: playersSQL, adapter: adapter)),
          expected
        )
        XCTAssertEqual(
          try AdapterPlayer.fetchSet(db, sql: playersSQL, adapter: adapter),
          Set(expected)
        )
        XCTAssertEqual(try AdapterPlayer.fetchAll(statement, adapter: adapter), expected)
        XCTAssertEqual(try AdapterPlayer.fetchOne(statement, adapter: adapter), expected[0])
        XCTAssertEqual(try Array(AdapterPlayer.fetchCursor(statement, adapter: adapter)), expected)
        XCTAssertEqual(try AdapterPlayer.fetchSet(statement, adapter: adapter), Set(expected))
        XCTAssertEqual(try AdapterPlayer.fetchAll(db, request), expected)
        XCTAssertEqual(try AdapterPlayer.fetchOne(db, request), expected[0])
        XCTAssertEqual(try Array(AdapterPlayer.fetchCursor(db, request)), expected)
        XCTAssertEqual(try AdapterPlayer.fetchSet(db, request), Set(expected))
        XCTAssertEqual(try request.fetchAll(db), expected)
        XCTAssertEqual(try request.fetchOne(db), expected[0])
        XCTAssertEqual(try Array(request.fetchCursor(db)), expected)
        XCTAssertEqual(try request.fetchSet(db), Set(expected))
      }
  }

  func testNamedScopesDecodeRequiredAndOptionalRecords() throws {
    try makeDatabaseQueue()
      .read { db in
        let row = try Row.fetchOne(
          db,
          sql: "SELECT 1 AS id, 'Arthur' AS name, NULL AS id, NULL AS name",
          adapter: joinedAdapter()
        )!
        XCTAssertTrue(row.isEmpty)
        XCTAssertTrue(row.containsNonNullValue)
        let player: AdapterPlayer = try row.decode(forKey: "player")
        XCTAssertEqual(player, AdapterPlayer(id: 1, name: "Arthur"))
        XCTAssertEqual(row["player"] as AdapterPlayer, player)
        XCTAssertEqual(row["player"] as AdapterPlayer?, player)
        XCTAssertNil(try row.decodeIfPresent(AdapterPlayer.self, forKey: "team"))
        XCTAssertNil(row["team"] as AdapterPlayer?)
        XCTAssertNil(try row.decodeIfPresent(AdapterPlayer.self, forKey: "missing"))
        XCTAssertThrowsError(try row.decode(AdapterPlayer.self, forKey: "team"))
        XCTAssertThrowsError(try row.decode(AdapterPlayer.self, forKey: "missing"))
      }
  }

  func testNestedDecodableAndFetchableRecords() throws {
    try makeDatabaseQueue()
      .read { db in
        let sql =
          "SELECT 1 AS id, 'Arthur' AS name, 2 AS id, 'Reds' AS name UNION ALL SELECT 3, 'Barbara', NULL, NULL"
        let records = try AdapterJoined.fetchAll(db, sql: sql, adapter: joinedAdapter())
        XCTAssertEqual(
          records,
          [
            AdapterJoined(
              player: AdapterPlayer(id: 1, name: "Arthur"),
              team: AdapterPlayer(id: 2, name: "Reds")
            ),
            AdapterJoined(player: AdapterPlayer(id: 3, name: "Barbara"), team: nil)
          ]
        )
        let plain = try AdapterPlainJoined.fetchAll(db, sql: sql, adapter: joinedAdapter())
        XCTAssertEqual(
          plain,
          [
            AdapterPlainJoined(
              player: AdapterPlainPlayer(id: 1, name: "Arthur"),
              team: AdapterPlainPlayer(id: 2, name: "Reds")
            ),
            AdapterPlainJoined(player: AdapterPlainPlayer(id: 3, name: "Barbara"), team: nil)
          ]
        )
        let custom = try AdapterManualJoined.fetchOne(db, sql: sql, adapter: joinedAdapter())
        XCTAssertEqual(custom?.player.name, "custom:Arthur")
      }
  }

  func testNestedContainerKeysAndNullInspection() throws {
    try makeDatabaseQueue()
      .read { db in
        let record = try AdapterInspectingRecord.fetchOne(
          db,
          sql: "SELECT 1 AS id, 'Arthur' AS name, NULL AS id, NULL AS name",
          adapter: joinedAdapter()
        )!
        XCTAssertEqual(record.keys, ["player", "team"])
        XCTAssertEqual(record.name, "Arthur")
      }
  }

  func testScopeNamesAndNestedRecordColumnStrategiesAreIndependent() throws {
    try makeDatabaseQueue()
      .read { db in
        let adapter = ScopeAdapter(
          base: EmptyRowAdapter(),
          scopes: ["thePlayer": SuffixRowAdapter(fromIndex: 0)]
        )
        let record = try AdapterCodedJoined.fetchOne(
          db,
          sql: "SELECT 'Arthur' AS first_name",
          adapter: adapter
        )
        XCTAssertEqual(record?.thePlayer.firstName, "Arthur")
        let wrongName = ScopeAdapter(
          base: EmptyRowAdapter(),
          scopes: ["the_player": SuffixRowAdapter(fromIndex: 0)]
        )
        XCTAssertThrowsError(
          try AdapterCodedJoined.fetchOne(
            db,
            sql: "SELECT 'Arthur' AS first_name",
            adapter: wrongName
          )
        )
        let plain = try AdapterPlainSnakeJoined.fetchOne(
          db,
          sql: "SELECT 'Arthur' AS first_name",
          adapter: ScopeAdapter(
            base: EmptyRowAdapter(),
            scopes: ["player": SuffixRowAdapter(fromIndex: 0)]
          )
        )
        XCTAssertEqual(plain?.player.firstName, "Arthur")
      }
  }

  func testColumnDecodingTakesPrecedenceOverScopeNames() throws {
    struct Payload: Decodable, FetchableRecord { var player: AdapterPlayer }
    try makeDatabaseQueue()
      .read { db in
        let record = try Payload.fetchOne(
          db,
          sql: "SELECT '{\"id\":42,\"name\":\"JSON\"}' AS player, 1 AS id, 'scope' AS name",
          adapter: ScopeAdapter(["player": RangeRowAdapter(1..<3)])
        )
        XCTAssertEqual(record?.player, AdapterPlayer(id: 42, name: "JSON"))
      }
  }

  func testScopeSearchIsBreadthFirstAndCopiesPreserveNestedScopes() throws {
    try makeDatabaseQueue()
      .read { db in
        let nested = ScopeAdapter(
          base: EmptyRowAdapter(),
          scopes: ["player": RangeRowAdapter(0..<2)]
        )
        let adapter = ScopeAdapter(
          base: EmptyRowAdapter(),
          scopes: [
            "outer": nested,
            "player": RangeRowAdapter(2..<4)
          ]
        )
        let row = try Row.fetchOne(
          db,
          sql: "SELECT 1 AS id, 'inner' AS name, 2 AS id, 'outer' AS name",
          adapter: adapter
        )!
        XCTAssertEqual(try row.decode(AdapterPlayer.self, forKey: "player").id, 2)
        XCTAssertEqual(row.scopesTree.names, ["outer", "player"])
        XCTAssertTrue(row.scopes["outer"]!.containsNonNullValue)
        XCTAssertEqual(row.copy(), row)
        XCTAssertEqual(row.copy().hashValue, row.hashValue)
        XCTAssertEqual(row.scopes["outer"]!.copy().scopes["player"]!, ["id": 1, "name": "inner"])
      }
  }

  func testAdaptedCursorViewsReuseRowsAndCopiesAreIndependent() throws {
    try makeDatabaseQueue()
      .read { db in
        let adapter = ScopeAdapter(
          base: RangeRowAdapter(1..<2),
          scopes: ["player": SuffixRowAdapter(fromIndex: 1)]
        )
        let cursor = try Row.fetchCursor(db, sql: playersSQL, adapter: adapter)
        let row = try cursor.next()!
        let scope = row.scopes["player"]!
        let copied = row.copy()
        let scopeCopy = scope.copy()
        XCTAssertTrue(try cursor.next() === row)
        XCTAssertEqual(row[0] as Int, 2)
        XCTAssertEqual(scope["name"] as String, "Barbara")
        XCTAssertEqual(copied[0] as Int, 1)
        XCTAssertEqual(copied.scopes["player"]!["name"] as String, "Arthur")
        XCTAssertEqual(scopeCopy["name"] as String, "Arthur")
        XCTAssertEqual(copied.unadapted["extra"] as Int, 99)
        XCTAssertEqual(copied.unscoped, ["id": 1])
        XCTAssertTrue(copied.unscoped.scopes.isEmpty)
        XCTAssertNil(try cursor.next())
      }
  }

  func testCustomAdapterAndSplittingRemainder() throws {
    try makeDatabaseQueue()
      .read { db in
        let sql = "SELECT 1 AS player_id, 'Arthur' AS player_name, 'Reds' AS team_name"
        let row = try Row.fetchOne(
          db,
          sql: sql,
          adapter: PrefixedColumnsAdapter(prefix: "player_")
        )!
        XCTAssertEqual(row, ["id": 1, "name": "Arthur"])
        let adapters = splittingRowAdapters(columnCounts: [1, 1])
        XCTAssertEqual(adapters.count, 3)
        let split = try Row.fetchOne(
          db,
          sql: sql,
          adapter: ScopeAdapter([
            "id": adapters[0], "name": adapters[1], "remaining": adapters[2]
          ])
        )!
        XCTAssertEqual(split.scopes["remaining"]!, ["team_name": "Reds"])
        let empty = splittingRowAdapters(columnCounts: [])
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(try Row.fetchOne(db, sql: sql, adapter: empty[0]), split.unadapted)
        let zero = splittingRowAdapters(columnCounts: [0])
        XCTAssertTrue(try Row.fetchOne(db, sql: sql, adapter: zero[0])!.isEmpty)
        XCTAssertEqual(try Row.fetchOne(db, sql: sql, adapter: zero[1]), split.unadapted)
      }
  }

  func testMissingColumnAndCustomErrorsOccurEvenWithoutRows() throws {
    try makeDatabaseQueue()
      .read { db in
        XCTAssertThrowsError(
          try Row.fetchAll(
            db,
            sql: "SELECT 1 AS id WHERE 0",
            adapter: ColumnMapping(["id": "missing"])
          )
        ) { error in
          XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_MISUSE)
        }
        XCTAssertThrowsError(
          try Row.fetchAll(db, sql: "SELECT 1 WHERE 0", adapter: ThrowingRowAdapter())
        ) { error in
          XCTAssertTrue(error is AdapterExpectedError)
        }
        let request = SQLRequest<Row>(sql: "SELECT 1 WHERE 0")
          .adapted { _ in throw AdapterExpectedError.expected }
        XCTAssertThrowsError(try request.fetchOne(db))
        XCTAssertEqual(try request.fetchCount(db), 0)
      }
  }

  func testPreparedRequestExposesAdapterAndBoundArguments() throws {
    try makeDatabaseQueue()
      .read { db in
        let request = SQLRequest<Int>(
          sql: "SELECT ?, ?",
          arguments: [99, 42],
          adapter: SuffixRowAdapter(fromIndex: 1),
          cached: true
        )
        let prepared = try request.makePreparedRequest(db)
        XCTAssertEqual(prepared.statement.arguments, [99, 42])
        XCTAssertEqual(try Int.fetchOne(prepared.statement, adapter: prepared.adapter), 42)
        var mutable = request
        mutable.adapter = SuffixRowAdapter(fromIndex: 0)
        XCTAssertEqual(try mutable.fetchOne(db), 99)
      }
  }

  func testAdaptedQueryInterfaceRequestsAndCounts() throws {
    try makeDatabaseQueue()
      .write { db in
        try db.execute(
          sql:
            "CREATE TABLE player(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO player VALUES (1,'Arthur'),(2,'Barbara')"
        )
        let request = Table<Row>("player").all().order(Column("id"))
          .adapted { _ in ColumnMapping(["displayName": "name"]) }
        XCTAssertEqual(
          try request.fetchAll(db),
          [["displayName": "Arthur"], ["displayName": "Barbara"]]
        )
        XCTAssertEqual(try request.fetchCount(db), 2)
        let empty = request.adapted { _ in EmptyRowAdapter() }
        XCTAssertEqual(try empty.fetchAll(db), [Row(), Row()])
        XCTAssertEqual(try empty.fetchCount(db), 2)
      }
  }

  func testReturningIsAdaptedAndLayoutFailuresDoNotWrite() throws {
    try makeDatabaseQueue()
      .write { db in
        try db.execute(sql: "CREATE TABLE player(id INTEGER PRIMARY KEY, name TEXT)")
        let adapter = ColumnMapping(["id": "inserted_id", "name": "inserted_name"])
        let record = try AdapterPlayer.fetchOne(
          db,
          sql:
            "INSERT INTO player VALUES (1,'Arthur') RETURNING id AS inserted_id, name AS inserted_name",
          adapter: adapter
        )
        XCTAssertEqual(record, AdapterPlayer(id: 1, name: "Arthur"))
        XCTAssertThrowsError(
          try Row.fetchOne(
            db,
            sql: "UPDATE player SET name='wrong' RETURNING id",
            adapter: ColumnMapping(["id": "missing"])
          )
        )
        XCTAssertThrowsError(
          try Row.fetchOne(
            db,
            sql: "DELETE FROM player RETURNING id",
            adapter: ThrowingRowAdapter()
          )
        )
        XCTAssertEqual(try String.fetchOne(db, sql: "SELECT name FROM player"), "Arthur")
        let request = SQLRequest<AdapterPlayer>(
          sql:
            "UPDATE player SET name='Barbara' RETURNING id AS inserted_id, name AS inserted_name",
          adapter: adapter
        )
        XCTAssertEqual(try request.fetchAll(db), [AdapterPlayer(id: 1, name: "Barbara")])
      }
  }
}
