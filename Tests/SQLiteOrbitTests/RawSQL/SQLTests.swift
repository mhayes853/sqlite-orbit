import SQLiteOrbit
import Testing

// Everything here has to compile identically with every trait on and off: it is the check that
// the `StructuredQueries` and `Foundation` traits only add to the raw SQL API.
@Suite
struct SQLTests {
  @Test
  func aLiteralWithoutInterpolationsBindsNothing() throws {
    let sql: SQL = "SELECT count(*) FROM reminders"
    #expect(sql.text == "SELECT count(*) FROM reminders")
    #expect(sql.bindings.isEmpty)
    #expect(try sql.validatedParts() == [.text(sql.text)])
  }

  @Test
  func writtenTextIsUsedAsItIsWithItsBindings() throws {
    let sql = SQL(text: "SELECT 'it''s' WHERE id = ?", bindings: [.integer(1)])
    #expect(sql.text == "SELECT 'it''s' WHERE id = ?")
    #expect(sql.bindings == [.integer(1)])
    #expect(sql == "SELECT 'it''s' WHERE id = \(1)")
    #expect(SQL(text: "SELECT 1") == "SELECT 1")
    #expect(try sql.validatedParts() == [.statement(text: sql.text, bindings: sql.bindings)])
    #expect(try SQL(parts: sql.validatedParts()) == sql)
  }

  @Test
  func interpolatedValuesAreBoundAsParameters() {
    let id = 42
    let rowID: Int64 = 7
    let score = 1.5
    let isCompleted = true
    let title = "Robert'); DROP TABLE reminders; --"
    let bytes: [UInt8] = [0xde, 0xad]
    let value = OrbitDatabaseValue.text("value")
    let sql: SQL = """
      INSERT INTO t VALUES (\(id), \(rowID), \(score), \(isCompleted), \(title), \(bytes), \(value))
      """
    #expect(sql.text == "INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?)")
    #expect(
      sql.bindings == [
        .integer(42), .integer(7), .real(1.5), .integer(1), .text(title),
        .blob([0xde, 0xad]), .text("value")
      ]
    )
  }

  @Test
  func interpolatedOptionalsBindNullWhenNil() {
    let id: Int? = nil
    let rowID: Int64? = nil
    let score: Double? = nil
    let isCompleted: Bool? = nil
    let title: String? = nil
    let bytes: [UInt8]? = nil
    let value: OrbitDatabaseValue? = nil
    let present: String? = "present"
    let sql: SQL = """
      VALUES (\(id), \(rowID), \(score), \(isCompleted), \(title), \(bytes), \(value), \(present))
      """
    #expect(sql.text == "VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    #expect(sql.bindings == [.null, .null, .null, .null, .null, .null, .null, .text("present")])
  }

  @Test
  func interpolatedLiteralsBindTheirDefaultTypes() {
    let sql: SQL = "VALUES (\(1), \(2.5), \(false), \("text"))"
    #expect(sql.text == "VALUES (?, ?, ?, ?)")
    #expect(sql.bindings == [.integer(1), .real(2.5), .integer(0), .text("text")])
  }

  @Test
  func interpolatedSQLIsSplicedWithItsParametersInOrder() throws {
    let filter: SQL = "list_id = \(3) AND title = \("Milk")"
    let sql: SQL = "SELECT \(1) FROM reminders WHERE \(filter) LIMIT \(10)"
    #expect(sql.text == "SELECT ? FROM reminders WHERE list_id = ? AND title = ? LIMIT ?")
    #expect(sql.bindings == [.integer(1), .integer(3), .text("Milk"), .integer(10)])
    #expect(
      try sql.validatedParts() == [
        .text("SELECT "), .binding(1), .text(" FROM reminders WHERE "),
        .text("list_id = "), .binding(3), .text(" AND title = "), .binding("Milk"),
        .text(" LIMIT "), .binding(10)
      ]
    )
    #expect(try SQL(parts: sql.validatedParts()) == sql)
  }

  @Test
  func rawTextIsSplicedAsItIs() {
    let direction = "DESC"
    let sql: SQL = "SELECT title FROM reminders ORDER BY title \(raw: direction)"
    #expect(sql.text == "SELECT title FROM reminders ORDER BY title DESC")
    #expect(sql.bindings.isEmpty)
  }

  @Test
  func quotedIdentifiersDoubleTheirQuotes() {
    let sql: SQL = "SELECT \(quote: "title") FROM \(quote: #"The "best" table"#)"
    #expect(sql.text == #"SELECT "title" FROM "The ""best"" table""#)
    #expect(sql.bindings.isEmpty)
  }

  @Test
  func appendingAndAddingKeepParametersInOrder() {
    var sql: SQL = "SELECT * FROM reminders WHERE id = \(1)"
    sql.append(" OR id = \(2)")
    let combined = sql + " OR id = \(3)"
    #expect(combined.text == "SELECT * FROM reminders WHERE id = ? OR id = ? OR id = ?")
    #expect(combined.bindings == [.integer(1), .integer(2), .integer(3)])
  }

  @Test
  func joinedPutsTheSeparatorBetweenElements() {
    let conditions: [SQL] = ["a = \(1)", "b = \(2)", "c = \(3)"]
    let joined = conditions.joined(separator: " AND \(true) AND ")
    #expect(joined.text == "a = ? AND ? AND b = ? AND ? AND c = ?")
    #expect(joined.bindings == [.integer(1), .integer(1), .integer(2), .integer(1), .integer(3)])
    #expect(conditions.joined().text == "a = ?b = ?c = ?")
    #expect([SQL]().joined(separator: ", ") == "")
  }

  @Test
  func equalityComparesTextAndBindings() {
    let first: SQL = "SELECT \(1)"
    let second: SQL = "SELECT \(1)"
    let third: SQL = "SELECT \(2)"
    #expect(first == second)
    #expect(first != third)
    let raw = SQL(text: "SELECT ?", bindings: [1])
    let partitioned = SQL(parts: [.text("SEL"), .text("ECT "), .binding(1)])
    #expect(Set([first, second, third, raw, partitioned]).count == 2)
  }

  @Test
  func debugDescriptionInlinesParametersOutsideQuotes() {
    let sql: SQL = "SELECT '?', \(1), \("it's"), \(nil as String?), \([0x0a] as [UInt8]), \(1.5)"
    #expect(sql.debugDescription == "SELECT '?', 1, 'it''s', NULL, X'0a', 1.5")
  }
}

@Suite
struct OrbitDatabaseValueTests {
  @Test
  func literalsMakeTheMatchingStorageClass() {
    let null: OrbitDatabaseValue = nil
    let integer: OrbitDatabaseValue = 42
    let real: OrbitDatabaseValue = 1.5
    let text: OrbitDatabaseValue = "text"
    #expect(null == .null)
    #expect(integer == .integer(42))
    #expect(real == .real(1.5))
    #expect(text == .text("text"))
  }

  @Test
  func accessorsReadOnlyTheirOwnStorageClass() {
    #expect(OrbitDatabaseValue.null.isNull)
    #expect(!OrbitDatabaseValue.integer(0).isNull)

    #expect(OrbitDatabaseValue.integer(3).integerValue == 3)
    #expect(OrbitDatabaseValue.real(3).integerValue == nil)
    #expect(OrbitDatabaseValue.text("3").integerValue == nil)

    #expect(OrbitDatabaseValue.real(2.5).realValue == 2.5)
    #expect(OrbitDatabaseValue.integer(2).realValue == 2)
    #expect(OrbitDatabaseValue.text("2").realValue == nil)

    #expect(OrbitDatabaseValue.text("a").textValue == "a")
    #expect(OrbitDatabaseValue.blob([0x61]).textValue == nil)

    #expect(OrbitDatabaseValue.blob([1, 2]).blobValue == [1, 2])
    #expect(OrbitDatabaseValue.text("").blobValue == nil)
    #expect(OrbitDatabaseValue.null.blobValue == nil)
  }
}
