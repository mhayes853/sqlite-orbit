#if Tagged
  import Tagged
  import Testing

  @testable import SQLiteOrbit

  #if UUIDV7
    import UUIDV7
  #endif

  #if StructuredQueries
    import StructuredQueriesSQLite
  #endif

  // Like `OrbitDatabaseValueConvertibleTests`, this compiles unchanged with Structured Queries on
  // or off. Structured Queries' `Tagged` trait also makes these types query expressions, and its
  // interpolation must not compete with binding them through their raw values here.
  @Suite
  struct TaggedConvertibleTests {
    @Test
    func taggedValuesRoundTripAsTheirRawValues() throws {
      try expectRoundTrip(ReminderID(42), .integer(42))
      try expectRoundTrip(Title("Get milk"), .text("Get milk"))
      try expectRoundTrip(ReminderID?.none, .null)
      try expectRoundTrip(Tagged<TaggedReminder, Priority>(.high), .integer(2))
      #if UUIDV7
        try expectRoundTrip(UUIDV7ID(uuidV7), .text(uuidV7String))
      #endif
    }

    @Test
    func taggedValuesReadOnlyWhatTheirRawValuesRead() {
      let text = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try ReminderID(orbitDatabaseValue: .text("42"))
      }
      #expect(text?.typeName == "Int")
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try Title(orbitDatabaseValue: .integer(1))
      }
      #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
        try Tagged<TaggedReminder, Int8>(orbitDatabaseValue: .integer(128))
      }
      #if UUIDV7
        #expect(throws: OrbitDatabaseValueConversionError.self) {
          try UUIDV7ID(orbitDatabaseValue: .text("f47ac10b-58cc-4372-a567-0e02b2c3d479"))
        }
      #endif
    }

    @Test
    func taggedValuesInterpolateAsParameters() {
      let sql: SQL = "SELECT \(ReminderID(1)), \(Title("a")), \(ReminderID?.none)"
      #expect(sql.text == "SELECT ?, ?, ?")
      #expect(sql.bindings == [.integer(1), .text("a"), .null])
      #if UUIDV7
        let uuidSQL: SQL = "SELECT \(UUIDV7ID(uuidV7)), \(uuidV7)"
        #expect(uuidSQL.bindings == [.text(uuidV7String), .text(uuidV7String)])
      #endif
    }

    #if BuiltInSQLite
      @Test
      func taggedValuesRoundTripThroughADatabase() async throws {
        let database = try inMemoryDatabase()
        let row = try await database.write { transaction in
          try transaction.execute("CREATE TABLE reminders (id INTEGER, title TEXT, parent INTEGER)")
          try transaction.execute(
            "INSERT INTO reminders VALUES (\(ReminderID(7)), \(Title("Milk")), \(ReminderID?.none))"
          )
          return try transaction.fetchOne(
            "SELECT id, title, parent, typeof(id), typeof(title) FROM reminders"
          ) { row in
            (
              try row[0, as: ReminderID.self],
              try row[column: "title", as: Title.self],
              try row[2, as: ReminderID?.self],
              try row[3, as: String.self],
              try row[4, as: String.self]
            )
          }
        }
        let values = try #require(row)
        #expect(values.0 == ReminderID(7))
        #expect(values.1 == Title("Milk"))
        #expect(values.2 == nil)
        #expect(values.3 == "integer")
        #expect(values.4 == "text")
      }

      @Test
      func typedFetchesReadTaggedValues() async throws {
        let database = try inMemoryDatabase()
        let (ids, titles, one, none) = try await database.read { transaction in
          (
            try transaction.fetchAll(
              "VALUES (\(ReminderID(1))), (2), (NULL)",
              as: ReminderID?.self
            ),
            try transaction.fetchAll("VALUES ('a'), ('b')", as: Title.self),
            try transaction.fetchOne("SELECT \(ReminderID(3))", as: ReminderID.self),
            try transaction.fetchOne("SELECT 1 WHERE 0", as: ReminderID.self)
          )
        }
        #expect(ids == [1, 2, nil])
        #expect(titles == ["a", "b"])
        #expect(one == 3)
        #expect(none == nil)
      }

      #if UUIDV7
        @Test
        func taggedVersion7UUIDsRoundTripThroughADatabase() async throws {
          let database = try inMemoryDatabase()
          let id = UUIDV7ID(uuidV7)
          let (all, one, stored) = try await database.write { transaction in
            try transaction.execute("CREATE TABLE items (id TEXT)")
            try transaction.execute(
              "INSERT INTO items VALUES (\(id)), (\(uuidV7String.uppercased()))"
            )
            return (
              try transaction.fetchAll("SELECT id FROM items", as: UUIDV7ID.self),
              try transaction.fetchOne("SELECT id FROM items WHERE id = \(id)") { row in
                try row[0, as: UUIDV7ID.self]
              },
              try transaction.fetchAll("SELECT id FROM items", as: String.self)
            )
          }
          #expect(all == [id, id])
          #expect(one == id)
          #expect(stored == [uuidV7String, uuidV7String.uppercased()])
        }
      #endif

      #if StructuredQueries
        @Test
        func taggedValuesAgreeWithStructuredQueries() async throws {
          let database = try inMemoryDatabase()
          let (decoded, read) = try await database.write { transaction in
            try transaction.execute("CREATE TABLE reminders (id INTEGER)")
            try transaction.execute("INSERT INTO reminders VALUES (\(ReminderID(1)))")
            try transaction.execute(
              #sql("INSERT INTO reminders VALUES (\(ReminderID(2)))", as: Void.self)
            )
            return (
              try transaction.fetchAll(#sql("SELECT id FROM reminders", as: ReminderID.self)),
              try transaction.fetchAll("SELECT id FROM reminders", as: ReminderID.self)
            )
          }
          #expect(decoded == [1, 2])
          #expect(read == [1, 2])
        }
      #endif
    #endif
  }

  private enum TaggedReminder {}
  private enum TaggedTitle {}

  private typealias ReminderID = Tagged<TaggedReminder, Int>
  private typealias Title = Tagged<TaggedTitle, String>

  private enum Priority: Int, OrbitDatabaseValueConvertible, Sendable {
    case low, medium, high
  }

  #if UUIDV7
    private typealias UUIDV7ID = Tagged<TaggedReminder, UUIDV7>
    private let uuidV7String = "01980c7f-b814-717d-b320-c7bc7b2d0c75"
    private let uuidV7 = UUIDV7(uuidString: uuidV7String)!
  #endif

  private func expectRoundTrip<Value: OrbitDatabaseValueConvertible & Equatable>(
    _ value: Value,
    _ stored: OrbitDatabaseValue,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    #expect(try value.orbitDatabaseValue() == stored, sourceLocation: sourceLocation)
    #expect(try Value(orbitDatabaseValue: stored) == value, sourceLocation: sourceLocation)
    let sql: SQL = "SELECT \(value)"
    #expect(sql.bindings == [stored], sourceLocation: sourceLocation)
  }
#endif
