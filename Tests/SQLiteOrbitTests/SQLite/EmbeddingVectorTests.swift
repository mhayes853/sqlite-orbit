#if Vectors && BuiltInSQLite
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

    @Test
    func otherNumericPrecisionsUseTaggedLittleEndianBlobs() throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let double = EmbeddingVector64<3> { [Double(1), -2, 0.5][$0] }
      let doubleBytes: [UInt8] = [
        0, 0, 0, 0, 0, 0, 240, 63,
        0, 0, 0, 0, 0, 0, 0, 192,
        0, 0, 0, 0, 0, 0, 224, 63,
        2
      ]
      #expect(double.orbitDatabaseValue() == .blob(doubleBytes))
      #expect(
        EmbeddingVector64<3>.VectorBytesRepresentation(queryOutput: double).queryBinding
          == .blob(doubleBytes)
      )
      #expect(try EmbeddingVector64<3>(orbitDatabaseValue: .blob(doubleBytes)) == double)

      #expect(try EmbeddingVector64<3>?(orbitDatabaseValue: .null) == nil)
    }

    @Test
    func otherNumericPrecisionsPreserveBitsAndEmptyDimensions() throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let doubleBits: [UInt64] = [
        0x8000_0000_0000_0000, 0x7ff0_0000_0000_0000,
        0x7ff8_0000_0000_1234, 1
      ]
      let double = EmbeddingVector64<4> { Double(bitPattern: doubleBits[$0]) }
      let decodedDouble = try EmbeddingVector64<4>(orbitDatabaseValue: double.orbitDatabaseValue())
      #expect(decodedDouble.map(\.bitPattern) == doubleBits)
      #expect(EmbeddingVector64<0>(repeating: 0).orbitDatabaseValue() == .blob([2]))
      #expect(try EmbeddingVector64<0>(orbitDatabaseValue: .blob([2])).isEmpty)
    }

    @Test
    func numericPrecisionDecodingRejectsWrongTagsAndDimensions() throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      for value in [
        OrbitDatabaseValue.blob([2]), .blob(Array(repeating: 0, count: 25)),
        .blob(Array(repeating: 0, count: 24) + [5]), .text("[1,2,3]")
      ] {
        #expect(throws: OrbitDatabaseValueConversionError.self) {
          try EmbeddingVector64<3>(orbitDatabaseValue: value)
        }
      }
      // Float32 blobs may carry Turso's optional format tag; use the same acceptance rules as
      // the structured query representation, while still validating the fixed dimension.
      let float = EmbeddingVector<3>(repeating: 1)
      let bytes = try #require(float.orbitDatabaseValue().blobValue)
      #expect(try EmbeddingVector<3>(orbitDatabaseValue: .blob(bytes + [1])) == float)
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

    #if !Turso
      @Test(arguments: SQLiteTestDriver.allCases)
      func otherNumericPrecisionsBindAndFetchWithRawSQL(_ driver: SQLiteTestDriver) async throws {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
          return
        }
        try await driver.withDatabase(
          schema: "CREATE TABLE precisions (float64 BLOB)"
        ) { database in
          let double = EmbeddingVector64<3> { [Double.pi, -2, .leastNonzeroMagnitude][$0] }
          try await database.write {
            try $0.execute("INSERT INTO precisions VALUES (\(double))")
          }
          let row = try await database.read {
            try $0.fetchOne("SELECT float64 FROM precisions", as: EmbeddingVector64<3>.self)
          }
          let stored = try #require(row)
          #expect(stored == double)
        }
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
    #endif
  }
#endif
