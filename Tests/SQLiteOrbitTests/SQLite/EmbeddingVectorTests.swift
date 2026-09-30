#if SQLiteVec && BuiltInSQLite && !Turso
  import SQLiteOrbit
  import Testing

  private var areEmbeddingVectorsAvailable: Bool {
    if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
      return true
    }
    return false
  }

  @Suite(.enabled(if: areEmbeddingVectorsAvailable))
  struct EmbeddingVectorTests {
    @Test
    func vectorBytesMatchSQLiteVecAndStructuredQueries() throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let vector = EmbeddingVector<3> { [Float(1), -2, 0.5][$0] }
      let bytes: [UInt8] = [0, 0, 128, 63, 0, 0, 0, 192, 0, 0, 0, 63]
      #expect(vector.orbitDatabaseValue() == .blob(bytes))
      #expect(vector.queryBinding == .blob(bytes))
      #expect(try EmbeddingVector<3>(orbitDatabaseValue: .blob(bytes)) == vector)
      #expect(try EmbeddingVector<3>?.none.orbitDatabaseValue() == .null)
      #expect(try EmbeddingVector<3>?(orbitDatabaseValue: .null) == nil)
      #if SystemSQLite
        #expect(SQLITE_VEC_VERSION.hasPrefix("v0."))
      #endif
    }

    @Test
    func conversionPreservesFloatBitsAndEmptyVectors() throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let bits: [UInt32] = [0x8000_0000, 0x7f80_0000, 0x7fc0_1234, 0x8000_0001]
      let vector = EmbeddingVector<4> { Float(bitPattern: bits[$0]) }
      let decoded = try EmbeddingVector<4>(orbitDatabaseValue: vector.orbitDatabaseValue())
      #expect(decoded.map(\.bitPattern) == bits)
      let empty = EmbeddingVector<0>(repeating: 0)
      #expect(empty.orbitDatabaseValue() == .blob([]))
      #expect(try EmbeddingVector<0>(orbitDatabaseValue: .blob([])).isEmpty)
    }

    @Test(arguments: [OrbitDatabaseValue.null, .integer(1), .real(1), .text("[1,2,3]")])
    func wrongStorageClassesReportConversionErrors(_ value: OrbitDatabaseValue) {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let error = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try EmbeddingVector<3>(orbitDatabaseValue: value)
      }
      #expect(error?.value == value)
      #expect(error?.reason == nil)
    }

    @Test(arguments: [0, 4, 11, 13, 16])
    func mismatchedDimensionsReportTheExpectedByteCount(_ size: Int) {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let value = OrbitDatabaseValue.blob(Array(repeating: 0, count: size))
      let error = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try EmbeddingVector<3>(orbitDatabaseValue: value)
      }
      #expect(error?.value == value)
      #expect(error?.reason == "Expected 12 vector bytes, found \(size)")
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func vectorsBindFetchAndSearchWithRawSQL(_ driver: SQLiteTestDriver) async throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      try await driver.withDatabase(
        schema: "CREATE VIRTUAL TABLE embeddings USING vec0(embedding float[3])"
      ) { database in
        let origin = EmbeddingVector<3>(repeating: 0)
        let neighbor = EmbeddingVector<3> { $0 == 0 ? 1 : 0 }
        try await database.write {
          try $0.execute("INSERT INTO embeddings VALUES (1, \(origin)), (2, \(neighbor))")
        }
        #expect(
          try await database.read {
            try $0.fetchOne(
              "SELECT embedding FROM embeddings WHERE rowid = 2",
              as: EmbeddingVector<3>.self
            )
          } == neighbor
        )
        #expect(
          try await database.read {
            try $0.fetchAll(
              """
              SELECT rowid FROM embeddings
              WHERE embedding MATCH \(origin) AND k = 2 ORDER BY distance
              """,
              as: Int64.self
            )
          } == [1, 2]
        )
        #if StructuredQueries
          #expect(
            try await database.read {
              try $0.fetchOne(
                #sql("SELECT \(Vec.distanceL2(origin, to: neighbor))", as: Double.self)
              )
            } == 1
          )
        #endif
      }
    }
  }
#endif
