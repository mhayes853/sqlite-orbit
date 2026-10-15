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
    func float64VectorsUseRawLittleEndianBlobsUnlessTursoTagged() throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let double = EmbeddingVector64<3> { [Double(1), -2, 0.5][$0] }
      let doubleBytes: [UInt8] = [
        0, 0, 0, 0, 0, 0, 240, 63,
        0, 0, 0, 0, 0, 0, 0, 192,
        0, 0, 0, 0, 0, 0, 224, 63
      ]
      #expect(double.orbitDatabaseValue() == .blob(doubleBytes))
      #expect(
        EmbeddingVector64<3>.VectorBytesRepresentation(queryOutput: double).queryBinding
          == .blob(doubleBytes)
      )
      #expect(try EmbeddingVector64<3>(orbitDatabaseValue: .blob(doubleBytes)) == double)

      let tagged = EmbeddingVector64<3>.TursoFloat64BytesRepresentation(queryOutput: double)
      #expect(tagged.orbitDatabaseValue() == .blob(doubleBytes + [2]))
      #expect(tagged.queryBinding == .blob(doubleBytes + [2]))
      #expect(
        try EmbeddingVector64<3>
          .TursoFloat64BytesRepresentation(
            orbitDatabaseValue: .blob(doubleBytes + [2])
          ) == tagged
      )

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
      #expect(EmbeddingVector64<0>(repeating: 0).orbitDatabaseValue() == .blob([]))
      #expect(try EmbeddingVector64<0>(orbitDatabaseValue: .blob([])).isEmpty)
      let tagged = EmbeddingVector64<0>
        .TursoFloat64BytesRepresentation(
          queryOutput: EmbeddingVector64<0>(repeating: 0)
        )
      #expect(tagged.orbitDatabaseValue() == .blob([2]))
    }

    @Test
    func numericPrecisionDecodingRejectsWrongFormatsAndDimensions() throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let tagged = Array(repeating: UInt8(0), count: 24) + [2]
      for value in [
        OrbitDatabaseValue.blob([2]), .blob(Array(repeating: 0, count: 16)), .blob(tagged),
        .text("[1,2,3]")
      ] {
        #expect(throws: OrbitDatabaseValueConversionError.self) {
          try EmbeddingVector64<3>(orbitDatabaseValue: value)
        }
      }
      for value in [
        OrbitDatabaseValue.blob(Array(tagged.dropLast())), .blob(Array(tagged.dropLast()) + [5]),
        .blob(Array(repeating: 0, count: 16) + [2])
      ] {
        #expect(throws: OrbitDatabaseValueConversionError.self) {
          try EmbeddingVector64<3>.TursoFloat64BytesRepresentation(orbitDatabaseValue: value)
        }
      }

      // Only the Turso representation accepts Turso's optional Float32 tag. Both still validate
      // the fixed dimension.
      let float = EmbeddingVector<3>(repeating: 1)
      let bytes = try #require(float.orbitDatabaseValue().blobValue)
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try EmbeddingVector<3>(orbitDatabaseValue: .blob(bytes + [1]))
      }
      #expect(
        try EmbeddingVector<3>
          .TursoFloat32BytesRepresentation(
            orbitDatabaseValue: .blob(bytes + [1])
          )
          .queryOutput == float
      )
      #expect(throws: OrbitDatabaseValueConversionError.self) {
        try EmbeddingVector<3>
          .TursoFloat32BytesRepresentation(
            orbitDatabaseValue: .blob(Array(bytes.dropLast(4)) + [1])
          )
      }
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

    // Float16 is unavailable on Intel macOS. Neither SQLiteVec nor Turso stores this format, but
    // the shared scalar codec still gives raw SQL a lossless blob.
    #if !(os(macOS) && arch(x86_64))
      @Test
      func float16VectorsUseLittleEndianBinary16Blobs() throws {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
          return
        }
        let vector = FixedEmbeddingVector<3, Float16>([1, -2, 0.5])
        let bytes: [UInt8] = [0x00, 0x3c, 0x00, 0xc0, 0x00, 0x38]
        #expect(vector.orbitDatabaseValue() == .blob(bytes))
        #expect(try FixedEmbeddingVector<3, Float16>(orbitDatabaseValue: .blob(bytes)) == vector)
        let error = #expect(throws: OrbitDatabaseValueConversionError.self) {
          try FixedEmbeddingVector<3, Float16>(orbitDatabaseValue: .blob(Array(bytes.dropLast())))
        }
        #expect(error?.reason == "Expected 6 vector bytes, found 5")
      }
    #endif

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

      #if StructuredQueries
        @Test(arguments: SQLiteTestDriver.allCases)
        func packedBinaryColumnsSearchAndSliceWithSQLiteVec(_ driver: SQLiteTestDriver) async throws
        {
          guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
            return
          }
          try await driver.withDatabase(
            configuration: vecConfiguration(),
            schema:
              "CREATE VIRTUAL TABLE binary_embeddings USING vec0(embedding bit[16], label text)"
          ) { database in
            let exact = try BinaryEmbeddingVector<16>(packedBytes: [0x05, 0x01])
            let near = try BinaryEmbeddingVector<16>(packedBytes: [0x85, 0x02])
            let vector = BinaryEmbeddingVector<16>.PackedBitsRepresentation(queryOutput: exact)
            try await database.write { transaction in
              try SQLiteBinaryEmbedding.insert {
                ($0.embedding, $0.label)
              } values: {
                (
                  Vec.bit(
                    BinaryEmbeddingVector<16>.PackedBitsRepresentation(queryOutput: near),
                    as: BinaryEmbeddingVector<16>.PackedBitsRepresentation.self
                  ),
                  "near"
                )
                (
                  Vec.bit(vector, as: BinaryEmbeddingVector<16>.PackedBitsRepresentation.self),
                  "exact"
                )
              }
              .execute(transaction)
            }
            try await database.read { transaction in
              let rows = try SQLiteBinaryEmbedding.order { $0.label }.fetchAll(transaction)
              #expect(rows.map(\.embedding) == [exact, near])
              let nearest = try SQLiteBinaryEmbedding.where { $0.embedding.match(vector) }
                .order { $0.distance }.limit(2).select { ($0.label, $0.distance) }
                .fetchAll(transaction)
              #expect(nearest.map(\.0) == ["exact", "near"])
              #expect(nearest.map(\.1) == [0, Double(exact.hammingDistance(to: near))])
              let scalar =
                try SQLiteBinaryEmbedding.order { $0.embedding.distanceHamming(to: vector) }
                .select { $0.embedding.distanceHamming(to: vector) }
                .fetchAll(transaction)
              #expect(scalar == nearest.map(\.1))
              let sliced = try #sql(
                "SELECT \(Vec.slice(vector, range: 8..<16, as: BinaryEmbeddingVector<8>.PackedBitsRepresentation.self))",
                as: BinaryEmbeddingVector<8>.PackedBitsRepresentation.self
              )
              .fetchOne(transaction)
              #expect(sliced?.packedBytes == [0x01])
              let columnSlices = try #require(
                try SQLiteBinaryEmbedding.where { $0.label.eq("near") }
                  .select {
                    (
                      $0.embedding.slice(start: 0, end: 8),
                      $0.embedding.slice(
                        0...7,
                        as: BinaryEmbeddingVector<8>.PackedBitsRepresentation.self
                      )
                    )
                  }
                  .fetchOne(transaction)
              )
              let nearPrefix = try BinaryEmbeddingVector<8>(packedBytes: [0x85])
              #expect(columnSlices.0 == Array(nearPrefix))
              #expect(columnSlices.1 == nearPrefix)
              #expect(
                try #sql("SELECT \(Vec.type(vector))", as: String.self)
                  .fetchOne(transaction) == "bit"
              )
            }
          }
        }

        @Test(arguments: SQLiteTestDriver.allCases)
        func columnSlicesAndComputedOperandsDecodeThroughOrbit(_ driver: SQLiteTestDriver)
          async throws
        {
          guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
            return
          }
          // Scalar helpers also apply to ordinary tables that store vector blobs.
          try await driver.withDatabase(
            configuration: vecConfiguration(),
            schema: "CREATE TABLE plain_embeddings (embedding BLOB NOT NULL, label TEXT NOT NULL)"
          ) { database in
            try await database.write { transaction in
              try SQLitePlainEmbedding.insert {
                SQLitePlainEmbedding(embedding: EmbeddingVector<3>([2, 0, 1]), label: "plain")
              }
              .execute(transaction)
            }
            try await database.read { transaction in
              let result = try #require(
                try SQLitePlainEmbedding.select {
                  (
                    $0.embedding.slice(0..<2),
                    $0.embedding.slice(0..<2, as: EmbeddingVector<2>.self),
                    $0.embedding.distanceL2(to: $0.embedding.normalize())
                  )
                }
                .fetchOne(transaction)
              )
              #expect(result.0 == [2, 0])
              #expect(result.1 == EmbeddingVector<2>([2, 0]))
              let distance = try #require(result.2)
              #expect(abs(distance - (Double(5).squareRoot() - 1)) < 0.000001)
              // Structured queries surface the vector's own error, unlike raw-SQL conversions.
              #expect(throws: VectorDecodingError.dimensionMismatch(expected: 3, actual: 2)) {
                try SQLitePlainEmbedding.select {
                  $0.embedding.slice(start: 0, length: 2, as: EmbeddingVector<3>.self)
                }
                .fetchOne(transaction)
              }
            }
          }
        }

        // Orbit decodes by storage class, so a helper's Swift type must match what SQLiteVec
        // returns: integer lengths and elements, and real distances.
        @Test
        func numericHelpersDecodeWithTheirSQLiteStorageClasses() throws {
          let database = try SQLiteQueue(path: ":memory:", configuration: vecConfiguration())
          let floats: [Float].VectorBytesRepresentation = [1, -2, 3, -4, 5, -6, 7, -8]
          let codes: [Int8].Int8BytesRepresentation = [1, -2, 3, -4, 5, -6, 7, -8]
          let bits: [Bool].PackedBitsRepresentation = [
            true, false, true, true, false, false, true, false
          ]
          let offset: [Int8].Int8BytesRepresentation = [0, 0, 0, 0, 0, 0, 0, 2]
          try database.readBlocking { transaction in
            let lengths = try #require(
              try #sql(
                "SELECT \(Vec.length(floats)), \(Vec.length(codes)), \(Vec.length(bits))",
                as: (Int, Int, Int).self
              )
              .fetchOne(transaction)
            )
            #expect([lengths.0, lengths.1, lengths.2] == [8, 8, 8])
            let distances = try #require(
              try #sql(
                """
                SELECT \(Vec.distanceL1(codes, to: offset)), \(Vec.distanceL1(floats, to: floats)), \
                \(Vec.distanceHamming(bits, to: bits))
                """,
                as: (Double, Double, Double).self
              )
              .fetchOne(transaction)
            )
            #expect([distances.0, distances.1, distances.2] == [38, 0, 0])
            #expect(
              try Vec.each(floats).order(by: \.rowid).select { $0.value }.fetchAll(transaction)
                == floats.queryOutput.map(Optional.some)
            )
            #expect(
              try Vec.each(codes).order(by: \.rowid).select(\.value).fetchAll(transaction)
                == codes.queryOutput
            )
            // SQLiteVec reports the most significant bit of each packed byte first.
            #expect(
              try Vec.each(bits).order(by: \.rowid).select(\.value).fetchAll(transaction)
                == bits.queryOutput.reversed()
            )
          }
        }

        // Missing vectors and undefined scores both reach Orbit as NULL, which the optional
        // helper results decode as nil rather than failing the storage-class check.
        @Test(arguments: SQLiteTestDriver.allCases)
        func missingVectorsAndUndefinedDistancesDecodeAsNil(_ driver: SQLiteTestDriver)
          async throws
        {
          try await driver.withDatabase(
            configuration: vecConfiguration(),
            schema: "CREATE TABLE nullable_embeddings (key INTEGER PRIMARY KEY, embedding BLOB)"
          ) { database in
            try await database.write {
              try $0.execute(
                """
                INSERT INTO nullable_embeddings
                VALUES (1, vec_f32('[3,4]')), (2, NULL), (3, vec_f32('[0,0]'))
                """
              )
            }
            let candidate: [Float].VectorBytesRepresentation = [3, 4]
            let missing: [Float].VectorBytesRepresentation? = nil
            try await database.read { transaction in
              let rows = try SQLiteNullableEmbedding.order(by: \.key)
                .select {
                  (
                    Vec.length($0.embedding), Vec.distanceL2($0.embedding, to: candidate),
                    Vec.distanceCosine($0.embedding, to: candidate)
                  )
                }
                .fetchAll(transaction)
              #expect(rows.map(\.0) == [2, nil, 2])
              #expect(rows.map(\.1) == [0, nil, 5])
              #expect(rows.map(\.2) == [0, nil, nil])
              let fallbacks =
                try SQLiteNullableEmbedding.select {
                  Vec.distanceL2($0.embedding, to: missing).ifnull(Double(-1))
                }
                .fetchAll(transaction)
              #expect(fallbacks == [-1, -1, -1])
              #expect(
                try SQLiteNullableEmbedding
                  .where { Vec.distanceCosine($0.embedding, to: candidate).isNot(nil) }
                  .select(\.key)
                  .fetchAll(transaction) == [1]
              )
              let components: [Float].VectorBytesRepresentation = [1, .nan, -2]
              #expect(
                try Vec.each(components).order(by: \.rowid).select { $0.value }
                  .fetchAll(transaction) == [1, nil, -2]
              )
            }
          }
        }

        @Test(arguments: SQLiteTestDriver.allCases)
        func int8ColumnsQuantizeSearchAndBindThroughRawSQL(_ driver: SQLiteTestDriver) async throws
        {
          guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
            return
          }
          try await driver.withDatabase(
            configuration: vecConfiguration(),
            schema: "CREATE VIRTUAL TABLE int8_embeddings USING vec0(embedding int8[4], label text)"
          ) { database in
            typealias Codes = FixedEmbeddingVector<4, Int8>.Int8BytesRepresentation
            let exact = Codes(queryOutput: FixedEmbeddingVector<4, Int8>([-128, 0, 64, 127]))
            let floats = EmbeddingVector<4>([-1, 0, 0.5, 1])
            try await database.write { transaction in
              try SQLiteInt8Embedding.insert {
                ($0.embedding, $0.label)
              } values: {
                (Vec.int8(exact, as: Codes.self), "exact")
                (Vec.quantizeInt8(floats, as: Codes.self), "quantized")
              }
              .execute(transaction)
              // Blob subtypes do not survive binding, so raw SQL tags the bound codes as well.
              let raw: [Int8].Int8BytesRepresentation = [-128, 0, 64, 126]
              try transaction.execute(
                "INSERT INTO int8_embeddings(embedding, label) VALUES (vec_int8(\(raw)), 'raw')"
              )
            }
            try await database.read { transaction in
              let rows = try SQLiteInt8Embedding.order { $0.label }.fetchAll(transaction)
              #expect(rows.map(\.label) == ["exact", "quantized", "raw"])
              #expect(
                rows.map { Array($0.embedding) } == [
                  [-128, 0, 64, 127], [-128, 0, 63, 126], [-128, 0, 64, 126]
                ]
              )
              let nearest = try SQLiteInt8Embedding.where { $0.embedding.match(exact) }
                .order { $0.distance }.limit(3).select { ($0.label, $0.distance) }
                .fetchAll(transaction)
              #expect(nearest.map(\.0) == ["exact", "raw", "quantized"])
              let scalar = try SQLiteInt8Embedding.order { $0.embedding.distanceL1(to: exact) }
                .select { $0.embedding.distanceL1(to: exact) }
                .fetchAll(transaction)
              #expect(scalar == [0, 1, 2])
              let stored = try transaction.fetchOne(
                "SELECT embedding FROM int8_embeddings WHERE label = 'raw'",
                as: [Int8].Int8BytesRepresentation.self
              )
              #expect(stored?.queryOutput == [-128, 0, 64, 126])
              // Fixed-size codes validate dimensions through Orbit's raw conversions too.
              #expect(throws: OrbitDatabaseColumnDecodingError.self) {
                try transaction.fetchOne(
                  "SELECT vec_slice(embedding, 0, 3) FROM int8_embeddings WHERE label = 'raw'",
                  as: Codes.self
                )
              }
            }
          }
        }
      #endif

      @Test(arguments: SQLiteTestDriver.allCases)
      func vectorsBindFetchAndSearchWithRawSQL(_ driver: SQLiteTestDriver) async throws {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
          return
        }
        try await driver.withDatabase(
          configuration: vecConfiguration(),
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
                try #sql("SELECT \(Vec.distanceL2(origin, to: neighbor))", as: Double.self)
                  .fetchOne($0)
              } == 1
            )
          #endif
        }
      }
    #endif
  }

  #if !Turso && StructuredQueries
    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    @Table("binary_embeddings")
    private struct SQLiteBinaryEmbedding: Vec0 {
      @Column(as: BinaryEmbeddingVector<16>.PackedBitsRepresentation.self)
      var embedding: BinaryEmbeddingVector<16>
      var label: String
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    @Table("plain_embeddings")
    private struct SQLitePlainEmbedding {
      var embedding: EmbeddingVector<3>
      var label: String
    }

    @Table("nullable_embeddings")
    private struct SQLiteNullableEmbedding {
      @Column(primaryKey: true)
      var key: Int
      @Column(as: [Float].VectorBytesRepresentation?.self)
      var embedding: [Float]?
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    @Table("int8_embeddings")
    private struct SQLiteInt8Embedding: Vec0 {
      @Column(as: FixedEmbeddingVector<4, Int8>.Int8BytesRepresentation.self)
      var embedding: FixedEmbeddingVector<4, Int8>
      var label: String
    }
  #endif
#endif
