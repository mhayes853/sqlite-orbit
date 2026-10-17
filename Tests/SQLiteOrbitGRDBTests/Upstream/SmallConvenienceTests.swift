// Shared application fixtures, run against both the overlay and GRDB 7.11.1.
import Foundation
import SQLiteOrbitGRDB
import XCTest

class SmallConvenienceTests: GRDBTestCase {
  func testRowNullInspectionAndCoalescing() throws {
    XCTAssertFalse(Row().containsNonNullValue)
    let nulls: Row = ["a": nil, "b": nil]
    XCTAssertFalse(nulls.containsNonNullValue)
    XCTAssertTrue(nulls.hasNull(atIndex: 0))
    XCTAssertTrue(nulls.hasNull(atIndex: 1))
    let values: Row = ["a": nil, "b": 0, "c": false, "d": "", "e": Data()]
    XCTAssertTrue(values.containsNonNullValue)
    for index in 1..<values.count { XCTAssertFalse(values.hasNull(atIndex: index)) }
    let duplicates: Row = ["name": nil, "NAME": "hidden", "fallback": "visible"]
    XCTAssertEqual(duplicates.coalesce(["missing", "NaMe", "FALLBACK"]) as String?, "visible")
    XCTAssertNil(duplicates.coalesce(["name"]) as String?)

    let database = try makeDatabaseQueue()
    try database.read { db in
      let cursor = try Row.fetchCursor(
        db,
        sql: "SELECT NULL AS a, NULL AS b UNION ALL SELECT NULL, 0"
      )
      let row = try XCTUnwrap(cursor.next())
      XCTAssertFalse(row.containsNonNullValue)
      XCTAssertTrue(row.hasNull(atIndex: 1))
      let copy = row.copy()
      XCTAssertTrue(try XCTUnwrap(cursor.next()).containsNonNullValue)
      XCTAssertFalse(row.hasNull(atIndex: 1))
      XCTAssertFalse(copy.containsNonNullValue)
      XCTAssertTrue(copy.hasNull(atIndex: 1))
    }
  }

  func testBitwiseAndUnaryExpressions() throws {
    let database = try makeDatabaseQueue()
    try database.read { db in
      let value = Column("value")
      let other = Column("other")
      let expressions: [any SQLSpecificExpressible] = [
        value & 3, 3 & value, value & other,
        value | 3, 3 | value, value | other,
        value << 1, 1 << value, value << other,
        value >> 1, 64 >> value, value >> other,
        ~value, -value, -(value + 1), ~(value + 1), -(-value),
        (value | 1) << 2, value & (other | 1)
      ]
      let selections = expressions.map { SQL($0) }.joined(separator: ", ")
      let literal: SQL = "SELECT \(selections) FROM (SELECT 6 AS value, 2 AS other)"
      let row = try XCTUnwrap(Row.fetchOne(db, SQLRequest<Row>(literal: literal)))
      XCTAssertEqual(
        Array(row.databaseValues),
        [2, 2, 2, 7, 7, 6, 12, 64, 24, 3, 1, 1, -7, -6, -7, -8, 6, 28, 2].map(\.databaseValue)
      )
      let absolute = abs(-5)
      XCTAssertEqual(absolute, 5)
      let integer = 6 & 3
      let optional: Bool? = nil
      let comparison = optional == true
      XCTAssertEqual(integer, 2)
      XCTAssertFalse(comparison)
    }
  }

  func testNullSafeIdentityAndOptionalComparisons() throws {
    let database = try makeDatabaseQueue()
    try database.read { db in
      let a = Column("a")
      let b = Column("b")
      let missing: Int? = nil
      let present: Int? = 1
      let expressions: [any SQLSpecificExpressible] = [
        a === b, a !== b, a === nil, nil === a, a !== nil, nil !== a,
        a === 1, 1 === a, a !== 1, 1 !== a,
        a === missing, missing === a,
        a == missing, a != missing, a == present, a != present,
        a == DatabaseValue.null, a != DatabaseValue.null
      ]
      let selections = expressions.map { SQL($0) }.joined(separator: ", ")
      let literal: SQL = "SELECT \(selections) FROM (SELECT NULL AS a, NULL AS b)"
      let row = try XCTUnwrap(Row.fetchOne(db, SQLRequest<Row>(literal: literal)))
      let expected: [Bool?] = [
        true, false, true, true, false, false, false, false, true, true, true, true, true, false,
        nil, nil, true, false
      ]
      for (index, expected) in expected.enumerated() {
        XCTAssertEqual(row[index] as Bool?, expected)
      }
    }
  }

  func testLikeEscapeAndExpressionArguments() throws {
    let database = try makeDatabaseQueue()
    try database.read { db in
      let value = Column("value")
      let pattern = Column("pattern")
      let escape = Column("escapeCharacter")
      let expressions: [any SQLSpecificExpressible] = [
        value.like("100!%", escape: "!"),
        value.like(pattern, escape: escape),
        value.like(pattern, escape: "!"),
        value.like("100!%", escape: escape),
        !value.like(pattern, escape: escape),
        value.like("100%"),
        value.like("100!%", escape: nil),
        value.like(pattern, escape: escape) == true
      ]
      let selections = expressions.map { SQL($0) }.joined(separator: ", ")
      let literal: SQL =
        "SELECT \(selections) FROM (SELECT '100%' AS value, '100!%' AS pattern, '!' AS escapeCharacter)"
      let row = try XCTUnwrap(Row.fetchOne(db, SQLRequest<Row>(literal: literal)))
      XCTAssertEqual(
        Array(row.databaseValues),
        [true, true, true, true, false, true, false, true].map(\.databaseValue)
      )
    }
  }

  func testSQLExpressionInitializationAndCoalesce() throws {
    let database = try makeDatabaseQueue()
    try database.read { db in
      let empty: [any SQLSpecificExpressible] = []
      let fallback: [any SQLSpecificExpressible] = [Column("value"), "fallback".databaseValue]
      let alternatives: [any SQLSpecificExpressible] = [
        Column("value"), Column("other"), "fallback".databaseValue
      ]
      let selections: [SQL] = [
        SQL(Column("value")), SQL("bound?".databaseValue),
        SQL(coalesce(empty)), SQL(coalesce([Column("value")])),
        SQL(coalesce(fallback)),
        SQL(coalesce(alternatives))
      ]
      let literal: SQL =
        "SELECT \(selections.joined(separator: ", ")) FROM (SELECT NULL AS value, 'other' AS other)"
      let row = try XCTUnwrap(Row.fetchOne(db, SQLRequest<Row>(literal: literal)))
      XCTAssertTrue(row.hasNull(atIndex: 0))
      XCTAssertEqual(row[1] as String, "bound?")
      XCTAssertTrue(row.hasNull(atIndex: 2))
      XCTAssertTrue(row.hasNull(atIndex: 3))
      XCTAssertEqual(row[4] as String, "fallback")
      XCTAssertEqual(row[5] as String, "other")
      let raw = SQL("SELECT 42")
      let built = try raw.build(db)
      XCTAssertEqual(built.sql, "SELECT 42")
      XCTAssertEqual(built.arguments, [])
      XCTAssertEqual(try Int.fetchOne(db, SQLRequest<Int>(literal: raw)), 42)
    }
  }
}
