#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  // Like `SQLTests`, this compiles unchanged under every trait, so typed reads are the raw SQL API
  // as a caller without Structured Queries writes it.
  @Suite
  struct RawSQLTypedRowTests {
    // MARK: - Row subscripts

    @Test
    func rowsConvertColumnsByPosition() async throws {
      let database = try inMemoryDatabase()
      let row = try await database.read { transaction in
        try transaction.fetchOne(
          "SELECT 1, 'Milk', 2.5, 0, X'dead', 2, NULL"
        ) { row in
          (
            try row[0, as: Int.self],
            try row[1, as: String.self],
            try row[2, as: Double.self],
            try row[3, as: Bool.self],
            try row[4, as: [UInt8].self],
            try row[5, as: TypedPriority.self],
            try row[6, as: Int?.self],
            try row[0, as: Int?.self],
            try row[6, as: OrbitDatabaseValue.self]
          )
        }
      }
      let values = try #require(row)
      #expect(values.0 == 1)
      #expect(values.1 == "Milk")
      #expect(values.2 == 2.5)
      #expect(values.3 == false)
      #expect(values.4 == [0xde, 0xad])
      #expect(values.5 == .high)
      #expect(values.6 == nil)
      #expect(values.7 == 1)
      #expect(values.8 == .null)
    }

    @Test
    func rowsConvertColumnsByTheFirstMatchingName() async throws {
      let database = try inMemoryDatabase()
      let row = try await database.read { transaction in
        try transaction.fetchOne(
          "SELECT 1 AS id, 'Milk' AS title, NULL AS priority, 2 AS id"
        ) { row in
          (
            try row[column: "id", as: Int.self],
            try row[column: "title", as: String.self],
            try row[column: "priority", as: TypedPriority?.self]
          )
        }
      }
      let values = try #require(row)
      #expect(values.0 == 1)
      #expect(values.1 == "Milk")
      #expect(values.2 == nil)
    }

    @Test
    func aMissingColumnThrowsRatherThanReadingAsNull() async throws {
      let database = try inMemoryDatabase()
      let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT 1 AS id") { row in
            try row[column: "priority", as: Int?.self]
          }
        }
      }
      #expect(error?.columnIndex == nil)
      #expect(error?.columnName == "priority")
      #expect(error?.reason == "to exist")
      #expect(error?.sql == nil)
      #expect(error?.underlyingError == nil)
      #expect(error?.description == #"Expected a column named "priority" to exist."#)
    }

    @Test
    func aConversionFailureNamesTheColumnAndCarriesTheUnderlyingError() async throws {
      let database = try inMemoryDatabase()
      let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT 1 AS id, 'abc' AS quantity") { row in
            try row[column: "quantity", as: Int.self]
          }
        }
      }
      #expect(error?.columnIndex == 1)
      #expect(error?.columnName == "quantity")
      #expect(error?.reason == "to decode Int, but found TEXT")
      #expect(error?.sql == nil)
      #expect(
        error?.description == #"Expected column 1 ("quantity") to decode Int, but found TEXT."#
      )
      let underlying = try #require(error?.underlyingError as? OrbitDatabaseValueConversionError)
      #expect(underlying.value == .text("abc"))
      #expect(underlying.typeName == "Int")
    }

    @Test
    func nullInANonOptionalColumnIsReportedAsSuch() async throws {
      let database = try inMemoryDatabase()
      let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT NULL AS title") { row in
            try row[0, as: String.self]
          }
        }
      }
      #expect(error?.columnIndex == 0)
      #expect(error?.columnName == "title")
      #expect(error?.reason == "to not be NULL")
      #expect(error?.underlyingError is OrbitDatabaseValueConversionError)
    }

    @Test
    func otherFailuresAreCarriedAsTheUnderlyingError() async throws {
      let database = try inMemoryDatabase()
      let overflow = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT 300 AS level") { row in
            try row[0, as: Int8.self]
          }
        }
      }
      #expect(overflow?.columnName == "level")
      #expect(overflow?.underlyingError is OrbitDatabaseIntegerOverflowError<Int64>)

      let unknown = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT 7 AS priority") { row in
            try row[0, as: TypedPriority.self]
          }
        }
      }
      #expect(unknown?.reason.hasPrefix("to decode TypedPriority, but found INTEGER (") == true)
      #expect(unknown?.underlyingError is OrbitDatabaseValueConversionError)
    }

    @Test
    func aRowCursorsRowsConvertTheirColumns() async throws {
      let database = try inMemoryDatabase()
      let values = try await database.read { transaction in
        var cursor = try transaction.rowCursor("VALUES (1, 'a'), (2, NULL)")
        var values: [(Int, String?)] = []
        while let row = try cursor.next() {
          values.append((try row[0, as: Int.self], try row[1, as: String?.self]))
        }
        return values
      }
      #expect(values.map(\.0) == [1, 2])
      #expect(values.map(\.1) == ["a", nil])
    }

    // MARK: - Fetching

    @Test
    func readTransactionsFetchTheFirstColumnAsAType() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.executeScript(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT, priority INTEGER);
          INSERT INTO items VALUES (1, 'a', 2), (2, 'b', NULL), (3, 'c', 0);
          """
        )
      }
      let (titles, priorities, count, missing) = try await database.read { transaction in
        (
          try transaction.fetchAll("SELECT title FROM items ORDER BY id", as: String.self),
          try transaction.fetchAll(
            "SELECT priority FROM items ORDER BY id",
            as: TypedPriority?.self
          ),
          try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self),
          try transaction.fetchOne("SELECT title FROM items WHERE id = \(99)", as: String.self)
        )
      }
      #expect(titles == ["a", "b", "c"])
      #expect(priorities == [.high, nil, .low])
      #expect(count == 3)
      #expect(missing == nil)
    }

    @Test
    func fetchingANullableColumnDistinguishesNoRowFromNull() async throws {
      let database = try inMemoryDatabase()
      let (null, none) = try await database.read { transaction in
        (
          try transaction.fetchOne("SELECT NULL", as: Int?.self),
          try transaction.fetchOne("SELECT NULL WHERE 0", as: Int?.self)
        )
      }
      #expect(null == .some(nil))
      #expect(none == nil)
    }

    @Test
    func fetchingThrowsForAValueThatDoesNotConvert() async throws {
      let database = try inMemoryDatabase()
      let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchAll("VALUES (1), ('two')", as: Int.self)
        }
      }
      #expect(error?.columnIndex == 0)
      #expect(error?.underlyingError is OrbitDatabaseValueConversionError)

      await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT 1", as: Double.self)
        }
      }
    }

    @Test
    func writeTransactionsFetchWhatReturningReportsAsAType() async throws {
      let database = try inMemoryDatabase()
      let (inserted, deleted, none) = try await database.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT)")
        let inserted = try transaction.fetchAll(
          "INSERT INTO items (title) VALUES ('a'), (NULL), ('c') RETURNING id",
          as: Int.self
        )
        let deleted = try transaction.fetchOne(
          "DELETE FROM items WHERE id = \(2) RETURNING title",
          as: String?.self
        )
        let none = try transaction.fetchOne(
          "DELETE FROM items WHERE id = \(99) RETURNING id",
          as: Int.self
        )
        return (inserted, deleted, none)
      }
      #expect(inserted == [1, 2, 3])
      #expect(deleted == .some(nil))
      #expect(none == nil)
    }
  }

  private enum TypedPriority: Int, OrbitDatabaseValueConvertible, Sendable {
    case low, medium, high
  }
#endif
