#if BuiltInSQLite && Foundation
  import _SQLiteOrbitFoundation
  import Testing

  @testable import SQLiteOrbit

  #if StructuredQueries
    import StructuredQueriesSQLite
  #endif

  @Suite
  struct RawSQLFoundationTests {
    // 2018-01-29 00:08:00.125 UTC, which has a fractional second to lose.
    private let date = Date(timeIntervalSince1970: 1_517_184_480.125)
    private let uuid = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!

    @Test
    func datesUUIDsAndDataBindAsTheirStoredSpelling() {
      let data = Data([0xde, 0xad])
      let missing: Date? = nil
      let sql: SQL = "VALUES (\(date), \(uuid), \(data), \(missing), \(uuid as UUID?))"
      #expect(sql.text == "VALUES (?, ?, ?, ?, ?)")
      #expect(
        sql.bindings == [
          .text("2018-01-29 00:08:00.125"),
          .text("deadbeef-dead-beef-dead-beefdeadbeef"),
          .blob([0xde, 0xad]),
          .null,
          .text("deadbeef-dead-beef-dead-beefdeadbeef")
        ]
      )
    }

    @Test
    func valuesConvertToAndFromFoundationTypes() throws {
      #expect(OrbitDatabaseValue(date).dateValue == date)
      #expect(OrbitDatabaseValue.text("2018-01-29 00:08:00").dateValue != nil)
      #expect(OrbitDatabaseValue.text("not a date").dateValue == nil)
      #expect(OrbitDatabaseValue.integer(0).dateValue == nil)

      #expect(OrbitDatabaseValue(uuid).uuidValue == uuid)
      #expect(OrbitDatabaseValue.text(uuid.uuidString).uuidValue == uuid)
      #expect(OrbitDatabaseValue.text("nope").uuidValue == nil)

      let data = Data([1, 2, 3])
      #expect(OrbitDatabaseValue(data) == .blob([1, 2, 3]))
      #expect(OrbitDatabaseValue(data).dataValue == data)
      #expect(OrbitDatabaseValue.text("").dataValue == nil)
    }

    @Test
    func foundationValuesRoundTripThroughADatabase() async throws {
      let database = try inMemoryDatabase()
      let data = Data([0x00, 0x01])
      let row = try await database.write { transaction in
        try transaction.execute("CREATE TABLE t (date TEXT, id TEXT, payload BLOB)")
        try transaction.execute("INSERT INTO t VALUES (\(date), \(uuid), \(data))")
        return try transaction.fetchOne("SELECT date, id, payload FROM t") { row in
          (row[0].dateValue, row[1].uuidValue, row[2].dataValue)
        }
      }
      #expect(row?.0 == date)
      #expect(row?.1 == uuid)
      #expect(row?.2 == data)
    }

    #if StructuredQueries
      @Test
      func sqlBindsDatesAndUUIDsByteForByteAsStructuredQueriesDoes() async throws {
        let raw: SQL = "SELECT \(date), \(uuid)"
        let structured = SQL(fragment: #sql("SELECT \(date), \(uuid)", as: Void.self).query)
        #expect(raw == structured)

        let database = try inMemoryDatabase()
        let stored = try await database.write { transaction in
          try transaction.execute("CREATE TABLE t (source TEXT, date, id)")
          try transaction.execute("INSERT INTO t VALUES ('raw', \(date), \(uuid))")
          try transaction.execute(
            #sql("INSERT INTO t VALUES ('structured', \(date), \(uuid))", as: Void.self)
          )
          return try transaction.fetchAll("SELECT hex(date), hex(id) FROM t ORDER BY source") {
            ($0[0].textValue ?? "", $0[1].textValue ?? "")
          }
        }
        #expect(stored.count == 2)
        #expect(stored[0] == stored[1])
      }

      @Test
      func fragmentsLowerTheirBindingsAsTheQueryBuilderAlwaysHas() async throws {
        let fragment: QueryFragment =
          "VALUES (\(bind: true), \(bind: 1.5), \(bind: "a"), \(bind: [UInt8]([1])))"
        let sql = SQL(fragment: fragment)
        #expect(sql.text == "VALUES (?, ?, ?, ?)")
        #expect(sql.bindings == [.integer(1), .real(1.5), .text("a"), .blob([1])])

        // An unsigned integer past `Int64.max` cannot be stored, which binding reports.
        let overflowing = SQL(fragment: "SELECT \(QueryBinding.uint(.max))")
        let database = try inMemoryDatabase()
        await #expect(throws: (any Error).self) {
          try await database.read { transaction in
            try transaction.fetchOne(overflowing) { $0[0] }
          }
        }
      }

      @Test
      func structuredQueriesExpressionsInterpolateIntoSQL() async throws {
        let database = try inMemoryDatabase()
        let titles = try await database.write { transaction in
          try transaction.execute(
            "CREATE TABLE rawSQLItems (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
          )
          try transaction.execute(RawSQLItem.insert { RawSQLItem.Draft(title: "Milk") })
          let isMilk = RawSQLItem.columns.title.eq("Milk")
          return try transaction.fetchAll(
            "SELECT title FROM rawSQLItems WHERE \(isMilk) AND id = \(1)"
          ) { $0[0].textValue }
        }
        #expect(titles == ["Milk"])
      }
    #endif
  }

  #if StructuredQueries
    @Table
    private struct RawSQLItem {
      let id: Int
      var title: String
    }
  #endif
#endif
