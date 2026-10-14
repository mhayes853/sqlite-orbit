import Foundation
import SQLiteOrbitGRDB
import Testing

@Suite("GRDB additional compatibility", .timeLimit(.minutes(1)))
struct AdditionalCompatibilityTests {
  @Test func preparedStatementsAndUncheckedArguments() throws {
    let queue = try DatabaseQueue()
    try queue.read { (db: Database) throws in
      let statement = try db.cachedStatement(sql: "SELECT ? AS a, ? AS b")
      #expect(statement.columnNames == ["a", "b"])
      statement.setUncheckedArguments([1])
      let row = try #require(try Row.fetchOne(statement))
      #expect(row["a"] as Int == 1)
      #expect(row["b"] as Int? == nil)
      statement.setUncheckedArguments([2, 3, 4])
      #expect(try Int.fetchOne(statement) == 2)
      statement.arguments = [5, 6]
      #expect(try Int.fetchOne(statement) == 5)
      let request: SQLRequest<Row> = "SELECT \("Arthur") AS name"
      let cursor = try request.fetchCursor(db)
      #expect(cursor.columnNames == ["name"])
      #expect(cursor.arguments == ["Arthur"])
      #expect(try cursor.next()?["name"] as String? == "Arthur")
      #expect(throws: DatabaseError.self) { try db.makeStatement(sql: "SELECT 1; SELECT 2") }
    }
  }
  @Test func recordKeyEncodingSurvivesRequestTypeErasure() throws {
    struct Event: Codable, FetchableRecord, PersistableRecord {
      let id: Date
      let name: String
      static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .millisecondsSince1970
      }
      static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
      }
    }
    let queue = try DatabaseQueue()
    let date = Date(timeIntervalSince1970: 123456)
    try queue.write { (db: Database) throws in
      try db.execute(sql: "CREATE TABLE event(id INTEGER PRIMARY KEY, name TEXT)")
      try Event(id: date, name: "hello").insert(db)
      #expect(try Event.fetchOne(db, id: date)?.name == "hello")
      #expect(
        try Event.filter(id: date).asRequest(of: Row.self).fetchOne(db)?["name"] as String?
          == "hello"
      )
    }
  }
  @Test func columnEnumsAndNativeMetadata() async throws {
    enum Columns: String, ColumnExpression { case value }
    let native = try SQLiteQueue(path: .memory)
    #expect(native.path == ":memory:")
    let writer: any DatabaseWriter = native
    #expect(writer.configuration.foreignKeysEnabled)
    try await native.write { db in
      try db.execute(sql: "CREATE TABLE t(value INTEGER); INSERT INTO t VALUES(42)")
      let request = Table<Int>("t").all().select(Columns.value).filter(Columns.value == 42)
        .order(Columns.value.desc)
      #expect(try request.fetchOne(db) == 42)
    }
    let erased = AnyDatabaseReader(native)
    #expect(erased.path == ":memory:")
    #expect(try await erased.read { try Int.fetchOne($0, sql: "SELECT value FROM t") } == 42)
  }
  @Test func numberedGapsAndDollarNames() throws {
    let queue = try DatabaseQueue()
    try queue.read { (db: Database) throws in
      #expect(try Int.fetchOne(db, sql: "SELECT ?3", arguments: [1, 2, 3]) == 3)
      #expect(
        try Int.fetchOne(
          db,
          sql: "SELECT $scope::name(suffix)",
          arguments: ["scope::name(suffix)": 42]
        ) == 42
      )
    }
  }
  @Test func primaryKeyInspectionDistinguishesRowidAliases() throws {
    let queue = try DatabaseQueue()
    try queue.write { (db: Database) throws in
      try db.execute(
        sql:
          "CREATE TABLE ordinary(id INTEGER PRIMARY KEY); CREATE TABLE other(id INTEGER PRIMARY KEY) WITHOUT ROWID"
      )
      #expect(try db.primaryKey("ordinary").rowIDColumn == "id")
      #expect(try db.primaryKey("other").rowIDColumn == nil)
      #expect(throws: DatabaseError.self) { try db.columns(in: "missing") }
    }
  }
  @Test func asyncMigrationOnNativeDriver() async throws {
    let native = try SQLiteQueue(path: .memory)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("create") { try $0.execute(sql: "CREATE TABLE t(value)") }
    try await migrator.migrate(native)
    #expect(try await native.read { try $0.tableExists("t") })
  }
}
