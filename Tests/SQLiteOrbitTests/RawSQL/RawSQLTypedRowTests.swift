#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  // Like `SQLTests`, this compiles unchanged under every trait, so typed reads are the raw SQL API
  // as a caller without Structured Queries writes it.
  @Suite
  struct RawSQLTypedRowTests {
    @Test
    func rowsConvertColumnsByPositionAndByTheFirstMatchingName() async throws {
      let database = try inMemoryDatabase()
      let row = try await database.read { transaction in
        try transaction.fetchOne(
          "SELECT 1 AS id, 'Milk' AS title, NULL AS priority, 2 AS id"
        ) { row in
          (
            try row[0, as: Int.self],
            try row[1, as: String.self],
            try row[2, as: TypedPriority?.self],
            try row[3, as: TypedPriority.self],
            try row[column: "id", as: Int.self],
            try row[column: "priority", as: OrbitDatabaseValue.self]
          )
        }
      }
      let values = try #require(row)
      #expect(values.0 == 1)
      #expect(values.1 == "Milk")
      #expect(values.2 == nil)
      #expect(values.3 == .high)
      #expect(values.4 == 1)
      #expect(values.5 == .null)
    }

    @Test
    func aMissingColumnThrowsRatherThanReadingAsNull() async throws {
      let database = try inMemoryDatabase()
      let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT 1 AS id") { try $0[column: "priority", as: Int?.self] }
        }
      }
      #expect(error?.columnIndex == nil)
      #expect(error?.columnName == "priority")
      #expect(error?.underlyingError == nil)
      #expect(error?.description == #"Expected a column named "priority" to exist."#)
    }

    @Test(
      arguments: [
        ("'abc'", "to decode Int8, but found TEXT"),
        ("NULL", "to not be NULL"),
        ("300", "to decode Int8, but Integer 300 overflows the type it is decoded as")
      ]
    )
    func aFailedConversionNamesTheColumnAndCarriesItsError(
      _ literal: String,
      _ reason: String
    ) async throws {
      let database = try inMemoryDatabase()
      let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT 1 AS id, \(raw: literal) AS level") { row in
            try row[column: "level", as: Int8.self]
          }
        }
      }
      #expect(error?.columnIndex == 1)
      #expect(error?.columnName == "level")
      #expect(error?.reason == reason)
      #expect(error?.sql == nil)
      #expect(error?.underlyingError != nil)
      #expect(error?.description == #"Expected column 1 ("level") \#(reason)."#)
    }

    @Test
    func readTransactionsFetchTheFirstColumnAsAType() async throws {
      let database = try inMemoryDatabase()
      let (titles, priorities, count, null, none) = try await database.read { transaction in
        (
          try transaction.fetchAll("VALUES ('a'), ('b')", as: String.self),
          try transaction.fetchAll("VALUES (2), (NULL), (0)", as: TypedPriority?.self),
          try transaction.fetchOne("SELECT 3", as: Int.self),
          try transaction.fetchOne("SELECT NULL", as: Int?.self),
          try transaction.fetchOne("SELECT NULL WHERE 0", as: Int?.self)
        )
      }
      #expect(titles == ["a", "b"])
      #expect(priorities == [.high, nil, .low])
      #expect(count == 3)
      #expect(null == .some(nil))
      #expect(none == nil)
    }

    @Test
    func writeTransactionsFetchWhatReturningReportsAsAType() async throws {
      let database = try inMemoryDatabase()
      let (inserted, deleted) = try await database.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT)")
        let inserted = try transaction.fetchAll(
          "INSERT INTO items (title) VALUES ('a'), (NULL) RETURNING id",
          as: Int.self
        )
        let deleted = try transaction.fetchOne(
          "DELETE FROM items WHERE id = \(2) RETURNING title",
          as: String?.self
        )
        return (inserted, deleted)
      }
      #expect(inserted == [1, 2])
      #expect(deleted == .some(nil))
    }
  }

  private enum TypedPriority: Int, OrbitDatabaseValueConvertible, Sendable {
    case low, medium, high
  }
#endif
