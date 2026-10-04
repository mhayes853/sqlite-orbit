#if StructuredQueries && BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Suite
  struct RawSQLStructuredRowTests {
    @Test
    func tablesAndSelectionsDecodePositionallyWithoutAdditionalConformances() async throws {
      let database = try inMemoryDatabase()
      let (tables, first, selections, titles) = try await database.read { transaction in
        (
          try transaction.fetchAll(SQLQueryExpression(itemsSQL, as: Item.self)),
          try transaction.fetchOne(SQLQueryExpression(itemsSQL, as: Item.self)),
          try transaction.fetchAll(
            #sql("SELECT 1, 'Milk' UNION ALL SELECT 2, 'Tea'", as: Summary.self)
          ),
          try transaction.fetchCursor(SQLQueryExpression(itemsSQL, as: Item.self))
            .filter { $0.id > 1 }
            .map(\.title)
            .collect()
        )
      }
      #expect(
        tables == [
          .init(id: 1, title: "Milk", priority: nil), .init(id: 2, title: "Tea", priority: 3)
        ]
      )
      #expect(first == tables.first)
      #expect(selections == [.init(id: 1, title: "Milk"), .init(id: 2, title: "Tea")])
      #expect(titles == ["Tea"])
    }

    @Test
    func queryOutputCanDifferFromTheRequestedRepresentation() async throws {
      let database = try inMemoryDatabase()
      let aliased: [Item] = try await database.read {
        try $0.fetchAll(SQLQueryExpression(itemsSQL, as: TableAlias<Item, Other>.self))
      }
      #expect(aliased.count == 2)
      #expect(aliased.first?.title == "Milk")
    }

    @Test
    func declaredRepresentationsAndGroupedColumnsUseTheExistingDecoder() async throws {
      let database = try inMemoryDatabase()
      let (dated, nested, absent) = try await database.read { transaction in
        (
          try transaction.fetchOne(#sql("SELECT 1, 1234", as: Dated.self)),
          try transaction.fetchOne(#sql("SELECT 1, 'Milk', NULL, 4", as: Grouped.self)),
          try transaction.fetchOne(#sql("SELECT NULL, NULL, NULL, 4", as: OptionalGrouped.self))
        )
      }
      #expect(dated?.date == Date(timeIntervalSince1970: 1234))
      #expect(nested?.item == .init(id: 1, title: "Milk", priority: nil))
      #expect(nested?.count == 4)
      #expect(absent?.item == nil)
      #expect(absent?.count == 4)
    }

    @Test
    func emptyResultsAndFirstRowFetchingKeepTheirExistingSemantics() async throws {
      let database = try inMemoryDatabase()
      let (none, empty, first) = try await database.read { transaction in
        (
          try transaction.fetchOne(#sql("SELECT 1, 'Milk' WHERE 0", as: Summary.self)),
          try transaction.fetchAll(#sql("", as: Summary.self)),
          try transaction.fetchOne(
            #sql("SELECT 1, 'Milk' UNION ALL SELECT 'bad', 'Tea'", as: Summary.self)
          )
        )
      }
      #expect(none == nil)
      #expect(empty.isEmpty)
      #expect(first == .init(id: 1, title: "Milk"))
    }

    @Test
    func writesDecodeReturningWithEagerAndLazyFetches() async throws {
      let database = try inMemoryDatabase()
      let (inserted, updated, deleted) = try await database.write { transaction in
        try transaction.execute("CREATE TABLE summaries (id INTEGER, title TEXT)")
        let inserted = try transaction.fetchAll(
          #sql(
            "INSERT INTO summaries VALUES (1, 'Milk'), (2, 'Tea') RETURNING id, title",
            as: Summary.self
          )
        )
        let updated = try transaction.fetchOne(
          #sql(
            "UPDATE summaries SET title = 'Coffee' WHERE id = 2 RETURNING id, title",
            as: Summary.self
          )
        )
        let deleted =
          try transaction.executeCursor(
            #sql("DELETE FROM summaries RETURNING id, title", as: Summary.self)
          )
          .collect()
        return (inserted, updated, deleted)
      }
      #expect(inserted.count == 2)
      #expect(updated == .init(id: 2, title: "Coffee"))
      #expect(deleted.count == 2)
    }

    @Test
    func statementAndDecodingErrorsPropagateThroughBothPaths() async throws {
      let database = try inMemoryDatabase()
      await #expect(throws: SQLiteError.self) {
        try await database.read {
          try $0.fetchAll(#sql("CREATE TABLE forbidden (id INTEGER)", as: Summary.self))
        }
      }
      await #expect(throws: SQLiteError.self) {
        try await database.read { try $0.fetchOne(#sql("SELECT FROM", as: Summary.self)) }
      }
      await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read {
          try $0.fetchCursor(#sql("SELECT 'bad', 'Milk'", as: Summary.self)).collect()
        }
      }
      await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { try $0.fetchAll(#sql("SELECT 1", as: Summary.self)) }
      }
    }

    @Test
    func namedAndStructuredQueriesUseTheirOwnDecoders() async throws {
      let database = try inMemoryDatabase()
      let (named, positional) = try await database.read { transaction in
        (
          try transaction.fetchAll("SELECT 'Milk' AS title, 1 AS id", as: Dual.self),
          try transaction.fetchAll(#sql("SELECT 1, 'Milk'", as: Dual.self))
        )
      }
      #expect(named == positional)
    }
  }

  private let itemsSQL: QueryFragment =
    "SELECT 1 AS arbitrary, 'Milk' AS names, NULL AS ignored UNION ALL SELECT 2, 'Tea', 3"

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    let title: String
    let priority: Int?
  }

  @Selection
  private struct Summary: Equatable, Sendable {
    let id: Int
    let title: String
  }

  @Selection
  private struct Dated: Sendable {
    let id: Int
    @Column(as: Date.UnixTimeRepresentation.self) let date: Date
  }

  @Selection
  private struct Grouped: Sendable {
    let item: Item
    let count: Int
  }

  @Selection
  private struct OptionalGrouped: Sendable {
    let item: Item?
    let count: Int
  }

  @OrbitRow
  @Selection
  private struct Dual: Equatable, Sendable {
    let id: Int
    let title: String
  }

  private enum Other: AliasName {}
#endif
