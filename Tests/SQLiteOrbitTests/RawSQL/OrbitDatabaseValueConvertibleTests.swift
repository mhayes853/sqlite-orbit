import Testing

@testable import SQLiteOrbit

#if Foundation
  import _SQLiteOrbitFoundation
#endif

#if StructuredQueries
  import StructuredQueriesSQLite
#endif

// Like `SQLTests`, this compiles unchanged under every trait, so a conformance behaves the same
// whether or not Structured Queries is also there to bind the same types.
@Suite
struct OrbitDatabaseValueConvertibleTests {
  // MARK: - Round trips

  @Test
  func integersRoundTripAsIntegers() throws {
    try expectRoundTrip(42, .integer(42))
    try expectRoundTrip(Int.min, .integer(Int64(Int.min)))
    try expectRoundTrip(Int8.min, .integer(-128))
    try expectRoundTrip(Int16.max, .integer(32_767))
    try expectRoundTrip(Int32.min, .integer(-2_147_483_648))
    try expectRoundTrip(Int64.max, .integer(.max))
    try expectRoundTrip(UInt(7), .integer(7))
    try expectRoundTrip(UInt8.max, .integer(255))
    try expectRoundTrip(UInt16.max, .integer(65_535))
    try expectRoundTrip(UInt32.max, .integer(4_294_967_295))
    try expectRoundTrip(UInt64(Int64.max), .integer(.max))
  }

  @Test
  func otherBuiltInTypesRoundTripInTheirStorageClass() throws {
    try expectRoundTrip(1.5, .real(1.5))
    try expectRoundTrip(Float(0.25), .real(0.25))
    try expectRoundTrip(true, .integer(1))
    try expectRoundTrip(false, .integer(0))
    try expectRoundTrip("Get milk", .text("Get milk"))
    try expectRoundTrip("", .text(""))
    try expectRoundTrip([UInt8]([0xde, 0xad]), .blob([0xde, 0xad]))
    try expectRoundTrip(OrbitDatabaseValue.real(2), .real(2))
    try expectRoundTrip(OrbitDatabaseValue.null, .null)
  }

  @Test
  func optionalsStoreNilAsNullAndReadNullAsNil() throws {
    try expectRoundTrip(Int?.none, .null)
    try expectRoundTrip(Int?.some(3), .integer(3))
    try expectRoundTrip(String?.some("a"), .text("a"))
    #expect(try Int?(orbitDatabaseValue: .null) == nil)
    #expect(try String?(orbitDatabaseValue: .null) == nil)
    #expect(try OrbitDatabaseValue?(orbitDatabaseValue: .null) == nil)
  }

  @Test
  func booleansReadAnyNonzeroIntegerAsTrue() throws {
    #expect(try Bool(orbitDatabaseValue: .integer(-3)))
    #expect(try !Bool(orbitDatabaseValue: .integer(0)))
  }

  // MARK: - Strictness

  @Test
  func readingIsStrictAboutTheStorageClass() {
    #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Double(orbitDatabaseValue: .integer(1))
    }
    #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Float(orbitDatabaseValue: .integer(1))
    }
    #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Int(orbitDatabaseValue: .text("1"))
    }
    #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Int(orbitDatabaseValue: .real(1))
    }
    #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Bool(orbitDatabaseValue: .text("true"))
    }
    #expect(throws: OrbitDatabaseValueConversionError.self) {
      try String(orbitDatabaseValue: .blob([0x61]))
    }
    #expect(throws: OrbitDatabaseValueConversionError.self) {
      try [UInt8](orbitDatabaseValue: .text("a"))
    }
  }

  @Test
  func nullOnlyReadsAsAnOptional() {
    let error = #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Int(orbitDatabaseValue: .null)
    }
    #expect(error?.value == .null)
    #expect(error?.typeName == "Int")
    #expect(error?.description == "Expected Int, found NULL")
  }

  @Test
  func conversionErrorsNameTheTypeAndTheValueFound() {
    let error = #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Int(orbitDatabaseValue: .text("abc"))
    }
    #expect(error?.value == .text("abc"))
    #expect(error?.typeName == "Int")
    #expect(error?.reason == nil)
    #expect(error?.description == "Expected Int, found TEXT 'abc'")
  }

  // MARK: - Overflow

  @Test
  func integersThatDoNotFitOverflowWhenRead() {
    #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
      try Int8(orbitDatabaseValue: .integer(128))
    }
    #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
      try Int16(orbitDatabaseValue: .integer(Int64(Int16.min) - 1))
    }
    #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
      try Int32(orbitDatabaseValue: .integer(Int64(Int32.max) + 1))
    }
    #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
      try UInt8(orbitDatabaseValue: .integer(256))
    }
    #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
      try UInt64(orbitDatabaseValue: .integer(-1))
    }
    #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
      try UInt(orbitDatabaseValue: .integer(-1))
    }
  }

  @Test
  func unsignedIntegersPastInt64MaxOverflowWhenStored() {
    #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
      try UInt64.max.orbitDatabaseValue()
    }
    #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
      try (UInt64(Int64.max) + 1).orbitDatabaseValue()
    }
    if UInt.bitWidth == 64 {
      #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
        try UInt.max.orbitDatabaseValue()
      }
    }
  }

  // MARK: - Raw representable

  @Test
  func rawRepresentableValuesConvertThroughTheirRawValue() throws {
    try expectRoundTrip(Priority.high, .integer(2))
    try expectRoundTrip(Status.done, .text("done"))
    try expectRoundTrip(Priority?.none, .null)
  }

  @Test
  func anUnknownRawValueFailsToConvert() {
    let error = #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Priority(orbitDatabaseValue: .integer(7))
    }
    #expect(error?.value == .integer(7))
    #expect(error?.typeName == "Priority")
    #expect(error?.reason != nil)
    #expect(error?.description.hasPrefix("Expected Priority, found INTEGER 7: ") == true)

    // The raw value's own failure comes through as it is.
    #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Priority(orbitDatabaseValue: .text("high"))
    }
  }

  // MARK: - Interpolation

  @Test
  func everyConformingTypeInterpolatesAsAParameter() {
    let small: Int8 = -1
    let unsigned: UInt32 = 5
    let ratio: Float = 0.5
    let priority: Priority? = .medium
    let status = Status.open
    let missing: Priority? = nil
    let sql: SQL = """
      VALUES (\(small), \(unsigned), \(ratio), \(priority), \(status), \(missing), \(Money(cents: 3)))
      """
    #expect(sql.text == "VALUES (?, ?, ?, ?, ?, ?, ?)")
    #expect(
      sql.bindings == [
        .integer(-1), .integer(5), .real(0.5), .integer(1), .text("open"), .null, .integer(3)
      ]
    )
  }

  @Test
  func storageValuesInterpolateByImplicitMemberAndNil() {
    let sql: SQL = """
      VALUES (\(.null), \(nil), \(.integer(1)), \(.text("a")), \(OrbitDatabaseValue.real(2)))
      """
    #expect(sql.text == "VALUES (?, ?, ?, ?, ?)")
    #expect(sql.bindings == [.null, .null, .integer(1), .text("a"), .real(2)])
  }

  @Test
  func aValueThatFailsToConvertBindsNullAndKeepsLaterParametersInPlace() {
    let sql: SQL = "VALUES (\(1), \(UInt64.max), \(Failing()), \(2))"
    #expect(sql.text == "VALUES (?, ?, ?, ?)")
    #expect(sql.bindings == [.integer(1), .null, .null, .integer(2)])
  }

  #if StructuredQueries
    @Test
    func structuredQueriesExpressionsStillInterpolate() {
      let sql: SQL = """
        SELECT \(ConvertibleReminder.columns.title) FROM "convertibleReminders" \
        WHERE \(ConvertibleReminder.columns.isCompleted) AND \(ConvertibleReminder.columns.id) > \(3)
        """
      #expect(
        sql.text
          == """
          SELECT "convertibleReminders"."title" FROM "convertibleReminders" \
          WHERE "convertibleReminders"."isCompleted" AND "convertibleReminders"."id" > ?
          """
      )
      #expect(sql.bindings == [.integer(3)])
    }
  #endif

  // MARK: - Databases

  #if BuiltInSQLite
    @Test
    func aCustomConformanceIsBoundWhenTheStatementRuns() async throws {
      let database = try inMemoryDatabase()
      let (balance, priority) = try await database.write { transaction in
        try transaction.execute("CREATE TABLE accounts (balance INTEGER, priority INTEGER)")
        try transaction.execute(
          "INSERT INTO accounts VALUES (\(Money(cents: 1_250)), \(Priority.high))"
        )
        return try transaction.fetchOne("SELECT balance, priority FROM accounts") { row in
          (try Money(orbitDatabaseValue: row[0]), try Priority(orbitDatabaseValue: row[1]))
        }!
      }
      #expect(balance == Money(cents: 1_250))
      #expect(priority == .high)
    }

    @Test
    func aConversionErrorIsThrownWhenTheStatementRunsRatherThanWhenItIsBuilt() async throws {
      let database = try inMemoryDatabase()
      // Building the SQL does not throw.
      let insert: SQL = "INSERT INTO t VALUES (\(1), \(Failing()))"
      let error = await #expect(throws: FailingError.self) {
        try await database.write { transaction in
          try transaction.execute("CREATE TABLE t (a, b)")
          try transaction.execute(insert)
        }
      }
      #expect(error != nil)
      let count = try await database.read { transaction in
        try transaction.fetchOne(
          "SELECT count(*) FROM sqlite_master WHERE name = 't'"
        ) { $0[0].integerValue }
      }
      #expect(count == 0)
    }

    @Test
    func anOverflowingUnsignedIntegerIsThrownWhenTheStatementRuns() async throws {
      let database = try inMemoryDatabase()
      await #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT \(UInt64.max)") { $0[0] }
        }
      }
    }
  #endif

  // MARK: - Foundation

  #if Foundation
    @Test
    func foundationValuesRoundTripInTheirStoredSpelling() throws {
      let date = Date(timeIntervalSince1970: 1_517_184_480.125)
      let uuid = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
      try expectRoundTrip(date, .text("2018-01-29 00:08:00.125"))
      try expectRoundTrip(uuid, .text("deadbeef-dead-beef-dead-beefdeadbeef"))
      try expectRoundTrip(Data([0xde, 0xad]), .blob([0xde, 0xad]))
      #expect(try UUID(orbitDatabaseValue: .text(uuid.uuidString)) == uuid)
      _ = try Date(orbitDatabaseValue: .text("2018-01-29 00:08:00"))
    }

    @Test
    func foundationValuesRefuseTheWrongStorageClassAndUnparseableText() {
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try Date(orbitDatabaseValue: .real(0))
      }
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try UUID(orbitDatabaseValue: .blob([0]))
      }
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try Data(orbitDatabaseValue: .text("a"))
      }
      let date = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try Date(orbitDatabaseValue: .text("not a date"))
      }
      #expect(date?.typeName == "Date")
      #expect(date?.reason != nil)
      let uuid = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try UUID(orbitDatabaseValue: .text("not a uuid"))
      }
      #expect(uuid?.typeName == "UUID")
      #expect(uuid?.reason != nil)
    }
  #endif
}

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

private enum Priority: Int, OrbitDatabaseValueConvertible {
  case low, medium, high
}

private enum Status: String, OrbitDatabaseValueConvertible {
  case open, done
}

private struct Money: OrbitDatabaseValueConvertible, Equatable {
  var cents: Int

  func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(cents))
  }

  init(cents: Int) {
    self.cents = cents
  }

  init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    cents = try Int(orbitDatabaseValue: value)
  }
}

private struct FailingError: Error {}

private struct Failing: ConvertibleToOrbitDatabaseValue {
  func orbitDatabaseValue() throws -> OrbitDatabaseValue {
    throw FailingError()
  }
}

#if StructuredQueries
  @Table
  struct ConvertibleReminder {
    let id: Int
    var title: String
    var isCompleted: Bool
  }
#endif
