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
          try transaction.fetchAll(itemsSQL, asStructuredRow: Item.self),
          try transaction.fetchOne(itemsSQL, asStructuredRow: Item.self),
          try transaction.fetchAll(
            "SELECT 1, 'Milk' UNION ALL SELECT 2, 'Tea'",
            asStructuredRow: Summary.self
          ),
          try transaction.fetchCursor(itemsSQL, asStructuredRow: Item.self)
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
        try $0.fetchAll(itemsSQL, asStructuredRow: TableAlias<Item, Other>.self)
      }
      #expect(aliased.count == 2)
      #expect(aliased.first?.title == "Milk")
    }

    @Test
    func declaredRepresentationsAndGroupedColumnsUseTheExistingDecoder() async throws {
      let database = try inMemoryDatabase()
      let (dated, nested, absent) = try await database.read { transaction in
        (
          try transaction.fetchOne("SELECT 1, 1234", asStructuredRow: Dated.self),
          try transaction.fetchOne("SELECT 1, 'Milk', NULL, 4", asStructuredRow: Grouped.self),
          try transaction.fetchOne(
            "SELECT NULL, NULL, NULL, 4",
            asStructuredRow: OptionalGrouped.self
          )
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
          try transaction.fetchOne("SELECT 1, 'Milk' WHERE 0", asStructuredRow: Summary.self),
          try transaction.fetchAll("", asStructuredRow: Summary.self),
          try transaction.fetchOne(
            "SELECT 1, 'Milk' UNION ALL SELECT 'bad', 'Tea'",
            asStructuredRow: Summary.self
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
          "INSERT INTO summaries VALUES (1, 'Milk'), (2, 'Tea') RETURNING id, title",
          asStructuredRow: Summary.self
        )
        let updated = try transaction.fetchOne(
          "UPDATE summaries SET title = 'Coffee' WHERE id = 2 RETURNING id, title",
          asStructuredRow: Summary.self
        )
        let deleted =
          try transaction.executeCursor(
            "DELETE FROM summaries RETURNING id, title",
            asStructuredRow: Summary.self
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
          try $0.fetchAll("CREATE TABLE forbidden (id INTEGER)", asStructuredRow: Summary.self)
        }
      }
      await #expect(throws: SQLiteError.self) {
        try await database.read { try $0.fetchOne("SELECT FROM", asStructuredRow: Summary.self) }
      }
      await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read {
          try $0.fetchCursor("SELECT 'bad', 'Milk'", asStructuredRow: Summary.self).collect()
        }
      }
      await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { try $0.fetchAll("SELECT 1", asStructuredRow: Summary.self) }
      }
    }

    @Test
    func labelsRemainUnambiguousForTypesSupportingBothConversions() async throws {
      let database = try inMemoryDatabase()
      let (named, positional) = try await database.read { transaction in
        (
          try transaction.fetchAll("SELECT 'Milk' AS title, 1 AS id", asRow: Dual.self),
          try transaction.fetchAll("SELECT 1, 'Milk'", asStructuredRow: Dual.self)
        )
      }
      #expect(named == positional)
    }
  }

  private let itemsSQL: SQL =
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
