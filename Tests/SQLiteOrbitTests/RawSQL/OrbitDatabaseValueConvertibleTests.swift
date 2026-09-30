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
  @Test
  func builtInTypesRoundTripThroughTheirStorageClass() throws {
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
    try expectRoundTrip(1.5, .real(1.5))
    try expectRoundTrip(Float(0.25), .real(0.25))
    try expectRoundTrip(true, .integer(1))
    try expectRoundTrip(false, .integer(0))
    try expectRoundTrip("Get milk", .text("Get milk"))
    try expectRoundTrip([UInt8]([0xde, 0xad]), .blob([0xde, 0xad]))
    try expectRoundTrip(OrbitDatabaseValue.real(2), .real(2))
    try expectRoundTrip(Int?.none, .null)
    try expectRoundTrip(String?.some("a"), .text("a"))
    try expectRoundTrip(Priority.high, .integer(2))
    try expectRoundTrip(Status.done, .text("done"))
    #expect(try Bool(orbitDatabaseValue: .integer(-3)))
    #if Foundation
      try expectRoundTrip(
        Date(timeIntervalSince1970: 1_517_184_480.125),
        .text("2018-01-29 00:08:00.125")
      )
      let uuid = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
      try expectRoundTrip(uuid, .text("deadbeef-dead-beef-dead-beefdeadbeef"))
      #expect(try UUID(orbitDatabaseValue: .text(uuid.uuidString)) == uuid)
      try expectRoundTrip(Data([0xde, 0xad]), .blob([0xde, 0xad]))
    #endif
  }

  @Test(arguments: [OrbitDatabaseValue.null, .integer(1), .real(1), .text("1"), .blob([1])])
  func eachTypeReadsOnlyItsOwnStorageClass(_ value: OrbitDatabaseValue) {
    func reads<Value: ConvertibleFromOrbitDatabaseValue>(_ type: Value.Type) -> Bool {
      do {
        _ = try Value(orbitDatabaseValue: value)
        return true
      } catch {
        #expect(error is OrbitDatabaseValueConversionError)
        return false
      }
    }
    #expect(reads(Int.self) == (value.integerValue != nil))
    #expect(reads(UInt8.self) == (value.integerValue != nil))
    #expect(reads(Bool.self) == (value.integerValue != nil))
    #expect(reads(Double.self) == (value == .real(1)))
    #expect(reads(Float.self) == (value == .real(1)))
    #expect(reads(String.self) == (value.textValue != nil))
    #expect(reads([UInt8].self) == (value.blobValue != nil))
    #expect(reads(Int?.self) == (value.isNull || value.integerValue != nil))
    #if Foundation
      #expect(!reads(Date.self))
      #expect(!reads(UUID.self))
      #expect(reads(Data.self) == (value.blobValue != nil))
      #expect(reads(OrbitUnixTimeDate.self) == (value.integerValue != nil))
      #expect(reads(OrbitJulianDayDate.self) == (value == .real(1)))
    #endif
  }

  @Test
  func conversionErrorsNameTheTypeAndTheValueFound() {
    let text = #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Int(orbitDatabaseValue: .text("abc"))
    }
    #expect(text?.value == .text("abc"))
    #expect(text?.typeName == "Int")
    #expect(text?.reason == nil)
    #expect(text?.description == "Expected Int, found TEXT 'abc'")

    let null = #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Int(orbitDatabaseValue: .null)
    }
    #expect(null?.description == "Expected Int, found NULL")

    let unknown = #expect(throws: OrbitDatabaseValueConversionError.self) {
      try Priority(orbitDatabaseValue: .integer(7))
    }
    #expect(
      unknown?.description == "Expected Priority, found INTEGER 7: no value has this raw value"
    )

    #if Foundation
      let date = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try Date(orbitDatabaseValue: .text("not a date"))
      }
      #expect(date?.reason != nil)
      let uuid = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try UUID(orbitDatabaseValue: .text("not a uuid"))
      }
      #expect(uuid?.reason != nil)
      let unixTime = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try OrbitUnixTimeDate(orbitDatabaseValue: .real(1))
      }
      #expect(unixTime?.typeName == "OrbitUnixTimeDate")
    #endif
  }

  @Test
  func integersThatDoNotFitOverflow() {
    #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
      try Int8(orbitDatabaseValue: .integer(128))
    }
    #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) {
      try UInt64(orbitDatabaseValue: .integer(-1))
    }
    #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
      try UInt64.max.orbitDatabaseValue()
    }
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
      let columns = ConvertibleReminder.columns
      let sql: SQL = """
        SELECT \(columns.title) FROM "convertibleReminders" \
        WHERE \(columns.isCompleted) AND \(columns.id) > \(3)
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

  #if BuiltInSQLite
    @Test
    func aCustomConformanceIsBoundWhenTheStatementRuns() async throws {
      let database = try inMemoryDatabase()
      let balance = try await database.write { transaction in
        try transaction.execute("CREATE TABLE accounts (balance INTEGER)")
        try transaction.execute("INSERT INTO accounts VALUES (\(Money(cents: 1_250)))")
        return try transaction.fetchOne("SELECT balance FROM accounts", as: Money.self)
      }
      #expect(balance == Money(cents: 1_250))
    }

    #if Foundation
      @Test
      func datesStoredAsNumbersRoundTripAndAgreeWithSQLite() async throws {
        let date = Date(timeIntervalSince1970: 1_517_184_480.125)
        let unixTime = OrbitUnixTimeDate(date)
        let julianDay = OrbitJulianDayDate(date)
        #expect(unixTime.orbitDatabaseValue() == .integer(1_517_184_480))
        #expect(julianDay.orbitDatabaseValue() == .real(2440587.5 + 1_517_184_480.125 / 86400))

        let database = try inMemoryDatabase()
        let row = try await database.write { transaction in
          try transaction.execute("CREATE TABLE t (unix INTEGER, julian REAL)")
          try transaction.execute("INSERT INTO t VALUES (\(unixTime), \(julianDay))")
          return try transaction.fetchOne(
            "SELECT unix, julian, unixepoch(\(date)), julianday(\(date)) FROM t"
          ) { row in
            (
              try row[0, as: OrbitUnixTimeDate.self].date,
              try row[1, as: OrbitJulianDayDate.self].date,
              try row[2, as: OrbitUnixTimeDate.self].date,
              try row[3, as: OrbitJulianDayDate.self].date
            )
          }
        }
        let (unix, julian, sqliteUnix, sqliteJulian) = try #require(row)
        #expect(unix == Date(timeIntervalSince1970: 1_517_184_480))
        #expect(sqliteUnix == unix)
        #expect(abs(julian.timeIntervalSince(date)) < 0.001)
        #expect(abs(sqliteJulian.timeIntervalSince(date)) < 0.001)
      }
    #endif

    @Test
    func aConversionErrorIsThrownWhenTheStatementRunsRatherThanWhenItIsBuilt() async throws {
      let database = try inMemoryDatabase()
      let insert: SQL = "INSERT INTO t VALUES (\(1), \(Failing()))"
      await #expect(throws: FailingError.self) {
        try await database.write { transaction in
          try transaction.execute("CREATE TABLE t (a, b)")
          try transaction.execute(insert)
        }
      }
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

private struct Money: OrbitDatabaseValueConvertible, Equatable, Sendable {
  var cents: Int

  init(cents: Int) {
    self.cents = cents
  }

  init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    cents = try Int(orbitDatabaseValue: value)
  }

  func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(cents))
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
