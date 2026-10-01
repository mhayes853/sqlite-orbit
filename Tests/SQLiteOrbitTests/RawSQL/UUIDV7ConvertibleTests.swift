#if UUIDV7
  import Testing
  import UUIDV7

  @testable import SQLiteOrbit

  #if StructuredQueries
    import StructuredQueriesSQLite
  #endif

  // Like `OrbitDatabaseValueConvertibleTests`, this compiles unchanged with Structured Queries on
  // or off, so interpolating and reading a `UUIDV7` never becomes ambiguous when it also binds
  // through Structured Queries.
  @Suite
  struct UUIDV7ConvertibleTests {
    @Test
    func identifiersRoundTripThroughTheirStorageClass() throws {
      try expectRoundTrip(id, .text(lowercase))
      try expectRoundTrip(OrbitBinaryUUIDV7(id), .blob(bytes))
      try expectRoundTrip(OrbitUppercaseUUIDV7(id), .text(uppercase))
      try expectRoundTrip(UUIDV7?.none, .null)
      try expectRoundTrip(UUIDV7?.some(id), .text(lowercase))
    }

    @Test
    func textInEitherCaseReadsAsEitherSpelling() throws {
      #expect(try UUIDV7(orbitDatabaseValue: .text(uppercase)) == id)
      #expect(try OrbitUppercaseUUIDV7(orbitDatabaseValue: .text(lowercase)).uuidV7 == id)
    }

    @Test
    func theBinaryFormMatchesTheIdentifiersBytesInOrder() throws {
      // The same order swift-uuidv7's `BytesRepresentation` binds, so either can read the other.
      #expect(OrbitBinaryUUIDV7(id).orbitDatabaseValue() == .blob(bytes))
      #expect(bytes == withUnsafeBytes(of: id.uuid, [UInt8].init))
    }

    @Test(arguments: [OrbitDatabaseValue.null, .integer(1), .real(1), .text("1"), .blob([1])])
    func eachFormReadsOnlyItsOwnStorageClass(_ value: OrbitDatabaseValue) {
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try UUIDV7(orbitDatabaseValue: value)
      }
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try OrbitBinaryUUIDV7(orbitDatabaseValue: value)
      }
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try OrbitUppercaseUUIDV7(orbitDatabaseValue: value)
      }
    }

    @Test
    func storageClassesOfAnotherFormAreRejected() {
      let blob = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try UUIDV7(orbitDatabaseValue: .blob(bytes))
      }
      #expect(blob?.typeName == "UUIDV7")
      #expect(blob?.reason == nil)
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try OrbitBinaryUUIDV7(orbitDatabaseValue: .text(lowercase))
      }
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try OrbitUppercaseUUIDV7(orbitDatabaseValue: .blob(bytes))
      }
    }

    @Test(arguments: ["not a uuid", version4, version4.uppercased(), ""])
    func textThatIsNotAVersion7UUIDIsRejected(_ text: String) {
      let plain = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try UUIDV7(orbitDatabaseValue: .text(text))
      }
      #expect(plain?.reason != nil)
      let uppercase = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try OrbitUppercaseUUIDV7(orbitDatabaseValue: .text(text))
      }
      #expect(uppercase?.typeName == "OrbitUppercaseUUIDV7")
      #expect(uppercase?.reason != nil)
    }

    @Test(arguments: [[], Array(bytes.prefix(15)), bytes + [0], version4Bytes])
    func blobsThatAreNotAVersion7UUIDAreRejected(_ blob: [UInt8]) {
      let error = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try OrbitBinaryUUIDV7(orbitDatabaseValue: .blob(blob))
      }
      #expect(error?.typeName == "OrbitBinaryUUIDV7")
      #expect(error?.reason != nil)
    }

    @Test
    func identifiersInterpolateAsParameters() {
      let sql: SQL = """
        SELECT \(id), \(OrbitBinaryUUIDV7(id)), \(OrbitUppercaseUUIDV7(id)), \(UUIDV7?.none)
        """
      #expect(sql.text == "SELECT ?, ?, ?, ?")
      #expect(sql.bindings == [.text(lowercase), .blob(bytes), .text(uppercase), .null])
    }

    #if BuiltInSQLite
      @Test
      func eachFormRoundTripsThroughADatabase() async throws {
        let database = try inMemoryDatabase()
        let row = try await database.write { transaction in
          try transaction.execute("CREATE TABLE ids (plain, binary, uppercase, missing)")
          try transaction.execute(
            """
            INSERT INTO ids VALUES (
              \(id), \(OrbitBinaryUUIDV7(id)), \(OrbitUppercaseUUIDV7(id)), \(UUIDV7?.none)
            )
            """
          )
          return try transaction.fetchOne(
            """
            SELECT plain, binary, uppercase, missing, \
            typeof(plain) || ' ' || typeof(binary) || ' ' || typeof(uppercase), hex(binary) \
            FROM ids
            """
          ) { row in
            (
              try row[0, as: UUIDV7.self],
              try row[1, as: OrbitBinaryUUIDV7.self].uuidV7,
              try row[2, as: OrbitUppercaseUUIDV7.self].uuidV7,
              try row[column: "missing", as: UUIDV7?.self],
              try row[0, as: String.self],
              try row[2, as: String.self],
              try row[4, as: String.self],
              try row[5, as: String.self]
            )
          }
        }
        let values = try #require(row)
        #expect(values.0 == id)
        #expect(values.1 == id)
        #expect(values.2 == id)
        #expect(values.3 == nil)
        #expect(values.4 == lowercase)
        #expect(values.5 == uppercase)
        #expect(values.6 == "text blob text")
        #expect(values.7 == uppercase.filter { $0 != "-" })
      }

      @Test
      func typedFetchesReadIdentifiers() async throws {
        let database = try inMemoryDatabase()
        let (all, one, binary, uppercased) = try await database.read { transaction in
          (
            try transaction.fetchAll("VALUES (\(id)), (\(uppercase)), (NULL)", as: UUIDV7?.self),
            try transaction.fetchOne("SELECT \(id)", as: UUIDV7.self),
            try transaction.fetchOne("SELECT \(OrbitBinaryUUIDV7(id))", as: OrbitBinaryUUIDV7.self),
            try transaction.fetchAll(
              "SELECT \(OrbitUppercaseUUIDV7(id))",
              as: OrbitUppercaseUUIDV7.self
            )
          )
        }
        #expect(all == [id, id, nil])
        #expect(one == id)
        #expect(binary == OrbitBinaryUUIDV7(id))
        #expect(uppercased == [OrbitUppercaseUUIDV7(id)])
      }

      @Test
      func textThatIsNotAVersion7UUIDFailsToFetch() async throws {
        let database = try inMemoryDatabase()
        let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
          try await database.read { transaction in
            try transaction.fetchOne("SELECT \(version4)", as: UUIDV7.self)
          }
        }
        #expect(error?.underlyingError is OrbitDatabaseValueConversionError)
      }

      #if StructuredQueries
        @Test
        func identifiersBoundHereDecodeThroughStructuredQueries() async throws {
          let database = try inMemoryDatabase()
          let (plain, binary, uppercased) = try await database.write { transaction in
            try transaction.execute("CREATE TABLE ids (plain, binary, uppercase)")
            try transaction.execute(
              """
              INSERT INTO ids VALUES (
                \(id), \(OrbitBinaryUUIDV7(id)), \(OrbitUppercaseUUIDV7(id))
              )
              """
            )
            return (
              try transaction.fetchOne(#sql("SELECT plain FROM ids", as: UUIDV7.self)),
              try transaction.fetchOne(
                #sql("SELECT binary FROM ids", as: UUIDV7.BytesRepresentation.self)
              ),
              try transaction.fetchOne(
                #sql("SELECT uppercase FROM ids", as: UUIDV7.UppercaseRepresentation.self)
              )
            )
          }
          #expect(plain == id)
          #expect(binary == id)
          #expect(uppercased == id)
        }

        @Test
        func identifiersBoundThroughStructuredQueriesReadHere() async throws {
          let database = try inMemoryDatabase()
          let row = try await database.write { transaction in
            try transaction.execute("CREATE TABLE ids (plain, binary, uppercase)")
            try transaction.execute(
              #sql(
                """
                INSERT INTO ids VALUES (
                  \(id), \(id, as: UUIDV7.BytesRepresentation.self), \
                  \(id, as: UUIDV7.UppercaseRepresentation.self)
                )
                """,
                as: Void.self
              )
            )
            return try transaction.fetchOne("SELECT plain, binary, uppercase FROM ids") { row in
              (
                try row[0, as: String.self],
                try row[0, as: UUIDV7.self],
                try row[1, as: OrbitBinaryUUIDV7.self].uuidV7,
                try row[2, as: OrbitUppercaseUUIDV7.self]
              )
            }
          }
          let values = try #require(row)
          #expect(values.0 == lowercase)
          #expect(values.1 == id)
          #expect(values.2 == id)
          #expect(try values.3.orbitDatabaseValue() == .text(uppercase))
        }
      #endif
    #endif
  }

  private let lowercase = "01980c7f-b814-717d-b320-c7bc7b2d0c75"
  private let uppercase = lowercase.uppercased()
  private let id = UUIDV7(uuidString: lowercase)!
  private let bytes: [UInt8] = [
    0x01, 0x98, 0x0c, 0x7f, 0xb8, 0x14, 0x71, 0x7d, 0xb3, 0x20, 0xc7, 0xbc, 0x7b, 0x2d, 0x0c, 0x75
  ]
  private let version4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
  private let version4Bytes: [UInt8] = [
    0xf4, 0x7a, 0xc1, 0x0b, 0x58, 0xcc, 0x43, 0x72, 0xa5, 0x67, 0x0e, 0x02, 0xb2, 0xc3, 0xd4, 0x79
  ]

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
