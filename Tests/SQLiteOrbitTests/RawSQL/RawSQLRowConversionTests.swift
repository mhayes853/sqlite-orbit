#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct RawSQLRowConversionTests {
    @Test
    func namedLookupIsPreparedOnceAndSharedAcrossRows() async throws {
      let names = TestCounter()
      var configuration = SQLiteConfiguration.default
      let name = configuration.library.columns.name
      configuration.library.columns.name = { statement, index in
        names.increment()
        return name(statement, index)
      }
      let database = try inMemoryDatabase(configuration: configuration)
      try await database.read { transaction in
        var cursor = try transaction.rowCursor(
          "SELECT 1 AS id, 'Milk' AS title UNION ALL SELECT 2, 'Tea'"
        )
        let baseline = names.value
        if let row = try cursor.next() {
          #expect(names.value == baseline)
          #expect(row.columnIndex(named: "title") == 1)
          #expect(names.value == baseline + 2)
          #expect(try row[column: "id", as: Int.self] == 1)
          #expect(row[column: "title"] == .text("Milk"))
          #expect(row.columnIndex(named: "missing") == nil)
          #expect(names.value == baseline + 2)
        } else {
          Issue.record("Expected a first row")
        }
        if let row = try cursor.next() {
          #expect(try row[column: "title", as: String.self] == "Tea")
          #expect(names.value == baseline + 2)
        } else {
          Issue.record("Expected a second row")
        }
      }
    }

    @Test
    func lookupsMatchExactBytesAndKeepTheFirstDuplicate() async throws {
      let database = try inMemoryDatabase()
      let indices = try await database.read { transaction in
        try transaction.fetchOne(
          "SELECT 1 AS id, 2 AS id, 3 AS ID, 4 AS \(quote: "é"), 5 AS \(quote: "e\u{301}")"
        ) { row in
          (
            row.columnIndex(named: "id"), row.columnIndex(named: "ID"),
            row.columnIndex(named: "é"), row.columnIndex(named: "e\u{301}"),
            try row[column: "id", as: Int.self],
            try row[column: "e\u{301}", as: Int.self]
          )
        }
      }
      let result = try #require(indices)
      #expect(result.0 == 0)
      #expect(result.1 == 2)
      #expect(result.2 == 3)
      #expect(result.3 == 4)
      #expect(result.4 == 1)
      #expect(result.5 == 5)
    }

    @Test
    func defaultLookupAndTypedReadsUseTheProtocolRequirement() throws {
      let fallback = ArrayRow(names: ["id", "title", "id"], values: [1, "Milk", 2])
      #expect(fallback.columnIndex(named: "id") == 0)
      #expect(fallback.columnIndex(named: "ID") == nil)
      #expect(try fallback[column: "title", as: String.self] == "Milk")
      let indexed = IndexedRow()
      #expect(try indexed[column: "id", as: Int.self] == 7)
      #expect(indexed[column: "id"] == .integer(7))
    }

    @Test
    func readFetchesAndLazyAlgorithmsInitializeOwnedValues() async throws {
      let database = try inMemoryDatabase()
      let (all, first, none, titles) = try await database.read { transaction in
        (
          try transaction.fetchAll(recordsSQL, asRow: Record.self),
          try transaction.fetchOne(recordsSQL, asRow: Record.self),
          try transaction.fetchOne("SELECT 1 WHERE 0", asRow: Record.self),
          try transaction.fetchCursor(recordsSQL, asRow: Record.self)
            .filter { $0.id > 1 }
            .map(\.title)
            .collect()
        )
      }
      #expect(
        all == [.init(id: 1, title: "Milk", priority: nil), .init(id: 2, title: "Tea", priority: 3)]
      )
      #expect(first == all.first)
      #expect(none == nil)
      #expect(titles == ["Tea"])
    }

    @Test
    func emptyQueriesAndFailedPreparationDoNotInitializeValues() async throws {
      let database = try inMemoryDatabase()
      let empty = try await database.read { try $0.fetchAll("", asRow: Record.self) }
      #expect(empty.isEmpty)
      await #expect(throws: SQLiteError.self) {
        try await database.read { try $0.fetchAll("SELECT FROM", asRow: Record.self) }
      }
    }

    @Test
    func missingOptionalColumnsAndInvalidValuesPropagateColumnErrors() async throws {
      let database = try inMemoryDatabase()
      let missing = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read {
          try $0.fetchAll("SELECT 1 AS id, 'Milk' AS title", asRow: Record.self)
        }
      }
      #expect(missing?.columnName == "priority")
      #expect(missing?.columnIndex == nil)
      let invalid = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read {
          try $0.fetchCursor(
            "SELECT 'bad' AS id, 'Milk' AS title, NULL AS priority",
            asRow: Record.self
          )
          .collect()
        }
      }
      #expect(invalid?.columnName == "id")
      #expect(invalid?.columnIndex == 0)
    }

    @Test
    func fetchOneDoesNotInitializeLaterRowsAndCustomErrorsPropagate() async throws {
      let database = try inMemoryDatabase()
      let first = try await database.read {
        try $0.fetchOne(
          "SELECT 1 AS id, 'Milk' AS title, NULL AS priority UNION ALL SELECT 'bad', 'Tea', 3",
          asRow: Record.self
        )
      }
      #expect(first?.id == 1)
      await #expect(throws: Rejection.self) {
        try await database.read { try $0.fetchAll("SELECT 1", asRow: RejectedRecord.self) }
      }
    }

    @Test
    func writerFetchesAndExecuteCursorDecodeReturningRows() async throws {
      let database = try inMemoryDatabase()
      let (inserted, updated, deleted) = try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE records (id INTEGER PRIMARY KEY, title TEXT, priority INTEGER)"
        )
        let inserted = try transaction.fetchAll(
          "INSERT INTO records VALUES (1, 'Milk', NULL), (2, 'Tea', 3) RETURNING *",
          asRow: Record.self
        )
        let updated = try transaction.fetchOne(
          "UPDATE records SET title = 'Coffee' WHERE id = 2 RETURNING *",
          asRow: Record.self
        )
        let deleted =
          try transaction.executeCursor("DELETE FROM records RETURNING *", asRow: Record.self)
          .collect()
        return (inserted, updated, deleted)
      }
      #expect(inserted.count == 2)
      #expect(updated == .init(id: 2, title: "Coffee", priority: 3))
      #expect(deleted.count == 2)
      let count = try await database.read {
        try $0.fetchOne("SELECT count(*) FROM records", as: Int.self)
      }
      #expect(count == 0)
    }

    @Test
    func readTransactionsRejectWritesAndMappingsFollowNewQueryLayouts() async throws {
      let database = try inMemoryDatabase()
      await #expect(throws: SQLiteError.self) {
        try await database.read {
          try $0.fetchAll("CREATE TABLE forbidden (id INTEGER)", asRow: Record.self)
        }
      }
      try await database.write {
        try $0.execute(
          "CREATE VIEW projection AS SELECT 1 AS id, 'Milk' AS title, NULL AS priority"
        )
      }
      let before = try await database.read {
        try $0.fetchAll("SELECT * FROM projection", asRow: Record.self)
      }
      try await database.write { transaction in
        try transaction.execute("DROP VIEW projection")
        try transaction.execute(
          "CREATE VIEW projection AS SELECT NULL AS priority, 'Milk' AS title, 1 AS id"
        )
      }
      let after = try await database.read {
        try $0.fetchAll("SELECT * FROM projection", asRow: Record.self)
      }
      #expect(before == after)
    }
  }

  private let recordsSQL: SQL =
    "SELECT NULL AS priority, 'Milk' AS title, 1 AS id UNION ALL SELECT 3, 'Tea', 2"

  private struct Record: ConvertibleFromOrbitDatabaseRow, Equatable, Sendable {
    let id: Int
    let title: String
    let priority: Int?

    init(id: Int, title: String, priority: Int?) {
      self.id = id
      self.title = title
      self.priority = priority
    }

    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(orbitDatabaseRow row: borrowing Row) throws
    {
      id = try row[column: "id", as: Int.self]
      title = try row[column: "title", as: String.self]
      priority = try row[column: "priority", as: Int?.self]
    }
  }

  private struct ArrayRow: OrbitDatabaseRow {
    let names: [String]
    let values: [OrbitDatabaseValue]
    var columnCount: Int { names.count }
    func columnName(at index: Int) -> String { names[index] }
    subscript(index: Int) -> OrbitDatabaseValue { values[index] }
  }

  private struct IndexedRow: OrbitDatabaseRow {
    var columnCount: Int { 1 }
    func columnName(at index: Int) -> String {
      fatalError("Successful typed reads must use columnIndex")
    }
    func columnIndex(named name: String) -> Int? { name == "id" ? 0 : nil }
    subscript(index: Int) -> OrbitDatabaseValue { .integer(7) }
  }

  private struct Rejection: Error {}
  private struct RejectedRecord: ConvertibleFromOrbitDatabaseRow, Sendable {
    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(orbitDatabaseRow row: borrowing Row) throws
    {
      throw Rejection()
    }
  }
#endif
