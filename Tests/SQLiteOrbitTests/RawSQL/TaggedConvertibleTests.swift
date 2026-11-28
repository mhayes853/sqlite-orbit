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

    #if BuiltInSQLite
      #if StructuredQueries
        @Test
        func taggedValuesAgreeWithStructuredQueries() async throws {
          let database = try inMemoryDatabase()
          let (decoded, read) = try await database.write { transaction in
            try transaction.execute("CREATE TABLE reminders (id INTEGER)")
            try transaction.execute("INSERT INTO reminders VALUES (\(ReminderID(1)))")
            try #sql("INSERT INTO reminders VALUES (\(ReminderID(2)))", as: Void.self)
              .execute(transaction)
            return (
              try #sql("SELECT id FROM reminders", as: ReminderID.self).fetchAll(transaction),
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
