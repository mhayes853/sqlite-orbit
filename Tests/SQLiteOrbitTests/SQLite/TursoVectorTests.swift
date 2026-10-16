#if Turso && Vectors && StructuredQueries
  import SQLiteOrbit
  import Testing

  // Import only Orbit: these tests also check that Vectors re-exports the Turso query helpers.
  // Each case opens an isolated, file-backed TursoPool using the published Rust engine artifact.
  @Suite
  struct TursoVectorTests {
    @Test
    func nativeVectorsAreAvailableOnEveryConnectionBeforeUserSetupAndAfterReopening() async throws {
      let setups = TestCounter()
      var configuration = SQLiteConfiguration.turso
      configuration.setups.append(
        SQLiteSetup { connection in
          try connection.execute("SELECT vector_extract(vector32('[1,2,3]'))")
          setups.increment()
        }
      )
      try await withTestDatabaseFile("turso-vectors") { file in
        for _ in 0..<2 {
          let database = try file.tursoPool(
            configuration: configuration,
            readerCount: 2,
            writerCount: 2
          )
          #expect(
            try await database.read {
              try #sql("SELECT \(TursoVec.extract(TursoVec.vector32("[1,2,3]")))", as: String.self)
                .fetchOne($0)
            } == "[1,2,3]"
          )
        }
      }
      #expect(setups.value == 8)
    }

    @Test
    func floatConversionsDecodeScalarsAndShareFloat32Bytes() async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let float32: [Float].VectorBytesRepresentation = [1, -2, 0.5]
        let float64: [Double].TursoFloat64BytesRepresentation = [1, -2, 0.5]
        try await database.read { transaction in
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector32("[1,-2,0.5]"))",
              as: [Float].VectorBytesRepresentation.self
            )
            .fetchOne(transaction)
              == float32.queryOutput
          )
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector("[1,-2,0.5]"))",
              as: [Float].VectorBytesRepresentation.self
            )
            .fetchOne(transaction)
              == float32.queryOutput
          )
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector64("[1,-2,0.5]"))",
              as: [Double].TursoFloat64BytesRepresentation.self
            )
            .fetchOne(transaction)
              == float64.queryOutput
          )
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector32(float64))",
              as: [Float].VectorBytesRepresentation.self
            )
            .fetchOne(transaction)
              == float32.queryOutput
          )
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector64(float32))",
              as: [Double].TursoFloat64BytesRepresentation.self
            )
            .fetchOne(transaction)
              == float64.queryOutput
          )
          let bytes = try #sql("SELECT \(TursoVec.vector32("[1,-2,0.5]"))", as: [UInt8].self)
            .fetchOne(transaction)
          #expect(float32.queryBinding == bytes.map { .blob($0) })
        }
      }
    }

    @Test(arguments: [1, 3, 4, 7, 8, 9, 16, 17])
    func compressedFormatsBindAndDecodeWithDimensionMetadata(_ dimensions: Int) async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let values = (0..<dimensions).map { Float($0 * 10) }
        let float8 = try Quantized8Vector(quantizing: values)
        let bits = (0..<dimensions).map { $0.isMultiple(of: 2) }
        let binary = [Bool].TursoBytesRepresentation(queryOutput: bits)
        let opposite = [Bool].TursoBytesRepresentation(queryOutput: bits.map { !$0 })
        let json = "[" + values.map(String.init(describing:)).joined(separator: ",") + "]"
        let binaryJSON = "[" + bits.map { $0 ? "1" : "-1" }.joined(separator: ",") + "]"
        try await database.read { transaction in
          let decodedVector = try #sql(
            "SELECT \(TursoVec.vector8(json))",
            as: Quantized8Vector.self
          )
          .fetchOne(transaction)
          let encoded = try #require(decodedVector)
          #expect(encoded == float8)
          #expect(encoded.vectorBytes == float8.vectorBytes)
          let decoded = encoded.decodedValues()
          #expect(decoded.count == dimensions)
          for (actual, expected) in zip(decoded, values) {
            #expect(abs(actual - expected) <= Float(max(1, dimensions - 1) * 10) / 255)
          }
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector1bit(binaryJSON))",
              as: [Bool].TursoBytesRepresentation.self
            )
            .fetchOne(transaction) == bits
          )
          #expect(
            try #sql("SELECT \(TursoVec.extract(binary))", as: String.self).fetchOne(transaction)
              == binaryJSON
          )
          #expect(
            try #sql("SELECT \(TursoVec.distanceCosine(binary, to: binary))", as: Double.self)
              .fetchOne(transaction)
              == 0
          )
          #expect(
            try #sql("SELECT \(TursoVec.distanceCosine(binary, to: opposite))", as: Double.self)
              .fetchOne(transaction) == Double(dimensions)
          )
          #expect(
            try #sql("SELECT \(TursoVec.distanceDot(binary, to: binary))", as: Double.self)
              .fetchOne(transaction) == -Double(dimensions)
          )
          #expect(
            try #sql("SELECT \(TursoVec.distanceDot(binary, to: opposite))", as: Double.self)
              .fetchOne(transaction) == Double(dimensions)
          )
          #expect(
            try #sql("SELECT \(TursoVec.distanceJaccard(binary, to: opposite))", as: Double.self)
              .fetchOne(transaction) == 1
          )
          #expect(
            try #sql("SELECT \(TursoVec.distanceL2(float8, to: float8))", as: Double.self)
              .fetchOne(transaction)
              == 0
          )
          let convertedVector = try #sql(
            "SELECT \(TursoVec.vector32(float8))",
            as: [Float].VectorBytesRepresentation.self
          )
          .fetchOne(transaction)
          let converted = try #require(convertedVector)
          #expect(converted.count == dimensions)
          for (actual, expected) in zip(converted, values) {
            #expect(abs(actual - expected) <= Float(max(1, dimensions - 1) * 10) / 255)
          }
        }
      }
    }

    @Test(arguments: ["float32", "float64", "float8", "sparse"])
    func numericDistanceHelpersAgreeAcrossSupportedFormats(_ format: String) async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let distances: [QueryFragment]
        switch format {
        case "float64":
          let left: [Double].TursoFloat64BytesRepresentation = [1, 0, 0]
          let right = TursoVec.vector64("[1,1,0]")
          distances = [
            TursoVec.distanceCosine(left, to: right).queryFragment,
            TursoVec.distanceL2(left, to: right).queryFragment,
            TursoVec.distanceDot(left, to: right).queryFragment,
            TursoVec.distanceJaccard(left, to: right).queryFragment
          ]
        case "float8":
          let left = try Quantized8Vector(quantizing: [1, 0, 0])
          let right = TursoVec.vector8("[1,1,0]")
          distances = [
            TursoVec.distanceCosine(left, to: right).queryFragment,
            TursoVec.distanceL2(left, to: right).queryFragment,
            TursoVec.distanceDot(left, to: right).queryFragment,
            TursoVec.distanceJaccard(left, to: right).queryFragment
          ]
        case "sparse":
          let left = try SparseFloat32Vector(compressing: [1, 0, 0])
          let right = TursoVec.vector32Sparse("[1,1,0]")
          distances = [
            TursoVec.distanceCosine(left, to: right).queryFragment,
            TursoVec.distanceL2(left, to: right).queryFragment,
            TursoVec.distanceDot(left, to: right).queryFragment,
            TursoVec.distanceJaccard(left, to: right).queryFragment
          ]
        default:
          let left: [Float].VectorBytesRepresentation = [1, 0, 0]
          let right = TursoVec.vector32("[1,1,0]")
          distances = [
            TursoVec.distanceCosine(left, to: right).queryFragment,
            TursoVec.distanceL2(left, to: right).queryFragment,
            TursoVec.distanceDot(left, to: right).queryFragment,
            TursoVec.distanceJaccard(left, to: right).queryFragment
          ]
        }
        let result = try await database.read {
          try #sql(
            "SELECT \(distances.joined(separator: ", "))",
            as: (Double, Double, Double, Double).self
          )
          .fetchOne($0)
        }
        let row = try #require(result)
        #expect(abs(row.0 - (1 - 1 / Double(2).squareRoot())) < 1e-6)
        #expect(abs(row.1 - 1) < 1e-6)
        #expect(abs(row.2 + 1) < 1e-6)
        #expect(abs(row.3 - 0.5) < 1e-6)
      }
    }

    @Test(arguments: [[Float](repeating: 0, count: 9), [0, 1, 0, -2, 0, 0, 3, 0, 0]])
    func sparseColumnsRoundTripSwiftAndEngineBytes(_ values: [Float]) async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let sparse = try SparseFloat32Vector(compressing: values)
        let json = "[" + values.map(String.init(describing:)).joined(separator: ",") + "]"
        try await database.write { transaction in
          try transaction.execute(
            "CREATE TABLE turso_sparse_embeddings (key INTEGER PRIMARY KEY, embedding BLOB)"
          )
          try TursoSparseEmbedding.insert { TursoSparseEmbedding(key: 1, embedding: sparse) }
            .execute(transaction)
          try TursoSparseEmbedding.insert {
            ($0.key, $0.embedding)
          } values: {
            (2, TursoVec.vector32Sparse(json))
          }
          .execute(transaction)
        }
        try await database.read { transaction in
          let rows = try TursoSparseEmbedding.order(by: \.key).fetchAll(transaction)
          #expect(rows.map(\.embedding) == [sparse, sparse])
          let bytes = try #sql("SELECT \(TursoVec.vector32Sparse(json))", as: [UInt8].self)
            .fetchOne(transaction)
          #expect(sparse.queryBinding == bytes.map { .blob($0) })
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector32(sparse))",
              as: [Float].VectorBytesRepresentation.self
            )
            .fetchOne(transaction) == values
          )
          let sliced = try #sql(
            "SELECT \(TursoVec.slice(sparse, from: 2, to: 8))",
            as: SparseFloat32Vector.self
          )
          .fetchOne(transaction)
          #expect(sliced?.denseValues() == Array(values[2..<8]))
          if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            #expect(
              try #sql(
                "SELECT \(TursoVec.vector32Sparse(json, as: SizedSparseFloat32Vector<9>.self))",
                as: SizedSparseFloat32Vector<9>.self
              )
              .fetchOne(transaction)
                == SizedSparseFloat32Vector<9>(compressing: EmbeddingVector<9> { values[$0] })
            )
          }
        }
      }
    }

    @Test
    func concatenationAndSlicingPreserveValuesAndValidateDimensions() async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let left: [Float].VectorBytesRepresentation = [1, -2]
        let double: [Double].TursoFloat64BytesRepresentation = [Double.pi, -2]
        try await database.read { transaction throws -> Void in
          let joined = TursoVec.concat(left, TursoVec.vector32("[0,4]"))
          let joinedDouble = TursoVec.concat(double, TursoVec.vector64("[0,4]"))
          #expect(
            try #sql("SELECT \(joined)", as: [Float].VectorBytesRepresentation.self)
              .fetchOne(transaction) == [1, -2, 0, 4]
          )
          #expect(
            try #sql("SELECT \(joinedDouble)", as: [Double].TursoFloat64BytesRepresentation.self)
              .fetchOne(transaction) == [Double.pi, -2, 0, 4]
          )
          #expect(
            try #sql(
              "SELECT \(TursoVec.slice(joined, from: 1, to: 3))",
              as: [Float].VectorBytesRepresentation.self
            )
            .fetchOne(transaction) == [-2, 0]
          )
          #expect(
            try #sql(
              "SELECT \(TursoVec.slice(joinedDouble, from: 1, to: 3))",
              as: [Double].TursoFloat64BytesRepresentation.self
            )
            .fetchOne(transaction) == [-2, 0]
          )
          if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            #expect(
              try #sql(
                "SELECT \(TursoVec.concat(left, TursoVec.vector32("[0,4]"), as: EmbeddingVector<4>.self))",
                as: EmbeddingVector<4>.self
              )
              .fetchOne(transaction) == EmbeddingVector<4> { [Float(1), -2, 0, 4][$0] }
            )
            #expect(
              try #sql(
                "SELECT \(TursoVec.slice(joinedDouble, from: 1, to: 3, as: EmbeddingVector64<2>.TursoFloat64BytesRepresentation.self))",
                as: EmbeddingVector64<2>.TursoFloat64BytesRepresentation.self
              )
              .fetchOne(transaction) == EmbeddingVector64<2> { [Double(-2), 0][$0] }
            )
            #expect(throws: VectorDecodingError.dimensionMismatch(expected: 3, actual: 2)) {
              try #sql(
                "SELECT \(TursoVec.slice(joined, from: 1, to: 3, as: EmbeddingVector<3>.self))",
                as: EmbeddingVector<3>.self
              )
              .fetchOne(transaction)
            }
          }
        }
        // The native engine can abort a transaction on an invalid slice. Inspect the original
        // error without a transaction, then verify that the pool can still execute the helper.
        let error = await #expect(throws: SQLiteError.self) {
          try await database.readWithoutTransaction {
            let joined = TursoVec.concat(left, TursoVec.vector32("[0,4]"))
            return try #sql(
              "SELECT \(TursoVec.slice(joined, from: 0, to: 5))",
              as: [Float].VectorBytesRepresentation.self
            )
            .fetchOne($0)
          }
        }
        #expect(error?.message?.contains("out of bounds") == true)
        #expect(error?.sql?.contains("vector_slice") == true)
        let reloaded = try await database.read {
          let joined = TursoVec.concat(left, TursoVec.vector32("[0,4]"))
          return try #sql("SELECT \(joined)", as: [Float].VectorBytesRepresentation.self)
            .fetchOne($0)
        }
        #expect(reloaded == [1, -2, 0, 4])
      }
    }

    @Test
    func structuredInsertsAndNamespaceHelpersSearchRealRows() async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        try await database.write { transaction in
          try transaction.execute(
            """
            CREATE TABLE turso_embeddings (
              key INTEGER PRIMARY KEY, title TEXT NOT NULL, embedding F32_BLOB(3)
            )
            """
          )
          for (key, title, json) in [
            (1, "nearest", "[1,0,0]"),
            (2, "neighbor", "[1,1,0]"),
            (3, "opposite", "[-1,0,0]")
          ] {
            try TursoEmbedding.insert {
              ($0.key, $0.title, $0.embedding)
            } values: {
              (key, title, TursoVec.vector32(json))
            }
            .execute(transaction)
          }
        }
        let vector: [Float].VectorBytesRepresentation = [1, 0, 0]
        let rows = try await database.read { transaction in
          try TursoEmbedding.order { TursoVec.distanceCosine($0.embedding, to: vector).asc() }
            .select {
              (
                $0.title, TursoVec.extract($0.embedding),
                TursoVec.distanceCosine($0.embedding, to: vector),
                TursoVec.distanceL2($0.embedding, to: TursoVec.vector32("[1,0,0]"))
              )
            }
            .fetchAll(transaction)
        }
        #expect(rows.map(\.0) == ["nearest", "neighbor", "opposite"])
        #expect(rows.map(\.1) == ["[1,0,0]", "[1,1,0]", "[-1,0,0]"])
        let cosines = try rows.map { try #require($0.2) }
        #expect(abs(cosines[0]) < 1e-6)
        #expect(abs(cosines[1] - (1 - 1 / Double(2).squareRoot())) < 1e-6)
        #expect(abs(cosines[2] - 2) < 1e-6)
        #expect(rows.map(\.3) == [0, 1, 2])
        #expect(
          try await database.read {
            try TursoEmbedding.order { TursoVec.distanceCosine($0.embedding, to: vector).asc() }
              .limit(2).select(\.title).fetchAll($0)
          } == ["nearest", "neighbor"]
        )
        #expect(
          try await database.read {
            try TursoEmbedding
              .where { TursoVec.distanceL2($0.embedding, to: vector).lt(Double?(1.5)) }
              .order(by: \.key).select(\.title).fetchAll($0)
          } == ["nearest", "neighbor"]
        )
      }
    }

    @Test
    func encodedColumnsRoundTripSwiftBindingsAndSQLConversions() async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let row = TursoEncodedEmbedding(
          key: 1,
          float64: [1, -2, 0.5],
          float8: try Quantized8Vector(quantizing: [0, 127, 255]),
          bits: [true, false, true]
        )
        try await database.write { transaction in
          try transaction.execute(
            """
            CREATE TABLE turso_encoded_embeddings (
              key INTEGER PRIMARY KEY, float64 F64_BLOB(3), float8 F8_BLOB(3), bits F1BIT_BLOB(3)
            )
            """
          )
          try TursoEncodedEmbedding.insert { row }.execute(transaction)
          try TursoEncodedEmbedding.insert {
            ($0.key, $0.float64, $0.float8, $0.bits)
          } values: {
            (
              2, TursoVec.vector64("[1,-2,0.5]"), TursoVec.vector8("[0,127,255]"),
              TursoVec.vector1bit("[1,-1,1]")
            )
          }
          .execute(transaction)
        }
        try await database.read { transaction in
          let rows = try TursoEncodedEmbedding.order(by: \.key).fetchAll(transaction)
          #expect(
            rows == [
              row,
              TursoEncodedEmbedding(
                key: 2,
                float64: row.float64,
                float8: row.float8,
                bits: row.bits
              )
            ]
          )
          let double = [Double].TursoFloat64BytesRepresentation(queryOutput: row.float64)
          let float8 = row.float8
          let binary = [Bool].TursoBytesRepresentation(queryOutput: row.bits)
          let distances =
            try TursoEncodedEmbedding.select {
              (
                TursoVec.distanceL2($0.float64, to: double),
                TursoVec.distanceCosine($0.float8, to: float8),
                TursoVec.distanceCosine($0.bits, to: binary), TursoVec.extract($0.bits)
              )
            }
            .fetchAll(transaction)
          #expect(distances.count == 2)
          for distance in distances {
            #expect(abs(try #require(distance.0)) < 1e-6)
            #expect(abs(try #require(distance.1)) < 1e-6)
            #expect(distance.2 == 0)
            #expect(distance.3 == "[1,-1,1]")
          }
        }
      }
    }

    @Test
    func encodedValuesRetainTheirBytesThroughRawAndStructuredQueries() async throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let quantized = try Quantized8Vector(codes: [10, 20, 30], scale: 2, shift: 1)
        let sparse = try SparseFloat32Vector(
          dimensions: 6,
          indices: [0, 2, 5],
          values: [-0.0, 1.5, 2.5]
        )
        let inline = try InlineQuantized8Vector<3>(vectorBytes: quantized.vectorBytes)
        let sized = try SizedSparseFloat32Vector<6>(vectorBytes: sparse.vectorBytes)
        try await database.write {
          try $0.execute(
            "CREATE TABLE encoded_values (quantized BLOB, sparse BLOB, inline_quantized BLOB, sized_sparse BLOB)"
          )
          try $0.execute(
            "INSERT INTO encoded_values VALUES (\(quantized), \(sparse), \(inline), \(sized))"
          )
        }
        let result = try await database.read {
          try $0.fetchOne("SELECT * FROM encoded_values") {
            (
              try $0[0, as: Quantized8Vector.self],
              try $0[1, as: SparseFloat32Vector.self],
              try $0[2, as: InlineQuantized8Vector<3>.self],
              try $0[3, as: SizedSparseFloat32Vector<6>.self]
            )
          }
        }
        let stored = try #require(result)
        #expect(stored.0 == quantized)
        #expect(stored.1 == sparse)
        #expect(stored.2 == inline)
        #expect(stored.3 == sized)
        try await database.write {
          try $0.execute(
            "INSERT INTO encoded_values VALUES (\(stored.0), \(stored.1), \(stored.2), \(stored.3))"
          )
        }
        try await database.read { transaction throws -> Void in
          let rows = try #sql(
            "SELECT * FROM encoded_values",
            as: (
              Quantized8Vector, SparseFloat32Vector, InlineQuantized8Vector<3>,
              SizedSparseFloat32Vector<6>
            )
            .self
          )
          .fetchAll(transaction)
          #expect(rows.count == 2)
          for row in rows {
            #expect(row.0.vectorBytes == quantized.vectorBytes)
            #expect(row.1.vectorBytes == sparse.vectorBytes)
            #expect(row.2.vectorBytes == inline.vectorBytes)
            #expect(row.3.vectorBytes == sized.vectorBytes)
          }
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector8("[0,127,255]", as: InlineQuantized8Vector<3>.self))",
              as: InlineQuantized8Vector<3>.self
            )
            .fetchOne(transaction)
              == InlineQuantized8Vector<3>(
                quantizing: EmbeddingVector<3> { [Float(0), 127, 255][$0] }
              )
          )
          #expect(
            try #sql("SELECT \(TursoVec.distanceL2(inline, to: quantized))", as: Double.self)
              .fetchOne(transaction) == 0
          )
          #expect(
            try #sql("SELECT \(TursoVec.distanceL2(sized, to: sparse))", as: Double.self)
              .fetchOne(transaction) == 0
          )
          #expect(throws: VectorDecodingError.dimensionMismatch(expected: 2, actual: 3)) {
            try #sql(
              "SELECT \(TursoVec.vector8("[0,127,255]", as: InlineQuantized8Vector<2>.self))",
              as: InlineQuantized8Vector<2>.self
            )
            .fetchOne(transaction)
          }
        }
      }
    }

    @Test
    func fixedSizeVectorsWorkWithTypedHelpersAndRawSQL() async throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let vector = EmbeddingVector<3> { [Float(1), -2, 0.5][$0] }
        let double = EmbeddingVector64<3> { Double(vector[$0]) }
        // Turso tags Float64 blobs, while EmbeddingVector64's own conversion stores raw components.
        let taggedDouble = EmbeddingVector64<3>.TursoFloat64BytesRepresentation(queryOutput: double)
        let binary = BinaryEmbeddingVector<3> { $0 != 1 }
        try await database.write { transaction in
          try transaction.execute(
            "CREATE TABLE vectors (embedding F32_BLOB(3), float64 F64_BLOB(3))"
          )
          try transaction.execute("INSERT INTO vectors VALUES (\(vector), \(taggedDouble))")
        }
        try await database.read { transaction in
          let stored = try transaction.fetchOne(
            "SELECT embedding FROM vectors",
            as: EmbeddingVector<3>.self
          )
          let storedDouble = try transaction.fetchOne(
            "SELECT float64 FROM vectors",
            as: EmbeddingVector64<3>.TursoFloat64BytesRepresentation.self
          )
          let nativeDouble = try transaction.fetchOne(
            "SELECT vector64('[1,-2,0.5]')",
            as: EmbeddingVector64<3>.TursoFloat64BytesRepresentation.self
          )
          #expect(throws: OrbitDatabaseColumnDecodingError.self) {
            try transaction.fetchOne(
              "SELECT vector64('[1,-2,0.5]')",
              as: EmbeddingVector64<3>.self
            )
          }
          let float32 = try #sql(
            "SELECT \(TursoVec.vector32(vector, as: EmbeddingVector<3>.self))",
            as: EmbeddingVector<3>.self
          )
          .fetchOne(transaction)
          let float64 = try #sql(
            "SELECT \(TursoVec.vector64(vector, as: EmbeddingVector64<3>.TursoFloat64BytesRepresentation.self))",
            as: EmbeddingVector64<3>.TursoFloat64BytesRepresentation.self
          )
          .fetchOne(transaction)
          let bits = try #sql(
            "SELECT \(TursoVec.vector1bit("[1,-1,1]", as: BinaryEmbeddingVector<3>.TursoBytesRepresentation.self))",
            as: BinaryEmbeddingVector<3>.TursoBytesRepresentation.self
          )
          .fetchOne(transaction)
          #expect(stored == vector)
          #expect(storedDouble == taggedDouble)
          #expect(nativeDouble == taggedDouble)
          #expect(float32 == vector)
          #expect(float64 == double)
          #expect(bits == binary)
        }
      }
    }

    @Test
    func packedBinaryColumnsPreserveDimensionsAndAgreeWithLocalHammingDistance() async throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let dense = EmbeddingVector<9>([1, -1, 1, -1, -1, -1, -1, 1, 1])
        let binary = BinaryEmbeddingVector<9>(quantizing: dense)
        let query = BinaryEmbeddingVector<9>.TursoBytesRepresentation(queryOutput: binary)
        let neighbor = try BinaryEmbeddingVector<9>(packedBytes: [0x85, 0x00])
        #expect(binary.packedBytes == [0x85, 0x01])
        try await database.write { transaction in
          try transaction.execute(
            "CREATE TABLE turso_binary_embeddings (key INTEGER PRIMARY KEY, embedding BLOB NOT NULL)"
          )
          try TursoBinaryEmbedding.insert {
            ($0.key, $0.embedding)
          } values: {
            (1, query)
            (
              2,
              TursoVec.vector1bit(
                dense,
                as: BinaryEmbeddingVector<9>.TursoBytesRepresentation.self
              )
            )
            (3, BinaryEmbeddingVector<9>.TursoBytesRepresentation(queryOutput: neighbor))
          }
          .execute(transaction)
        }
        try await database.read { transaction throws -> Void in
          let rows = try TursoBinaryEmbedding.order { $0.key }.fetchAll(transaction)
          #expect(rows.map(\.embedding) == [binary, binary, neighbor])
          let distances = try TursoBinaryEmbedding.order { $0.key }
            .select {
              TursoVec.distanceHamming($0.embedding, to: query)
            }
            .fetchAll(transaction)
          #expect(distances == rows.map { Double($0.embedding.hammingDistance(to: binary)) })
          #expect(distances == [0, 0, 1])
          let variable = [Bool].TursoBytesRepresentation(queryOutput: Array(neighbor))
          #expect(
            try #sql("SELECT \(TursoVec.distanceHamming(query, to: variable))", as: Double.self)
              .fetchOne(transaction) == 1
          )
          #expect(
            try transaction.fetchOne(
              "SELECT embedding FROM turso_binary_embeddings WHERE key = 1",
              as: [UInt8].self
            )
              == query.vectorBytes
          )
          // Nine and ten logical dimensions have the same packed byte count. Turso's metadata
          // must still reject decoding a nine-dimensional value as ten dimensions.
          #expect(throws: VectorDecodingError.dimensionMismatch(expected: 10, actual: 9)) {
            try #sql("SELECT \(query)", as: BinaryEmbeddingVector<10>.TursoBytesRepresentation.self)
              .fetchOne(transaction)
          }
        }
      }
    }

    @Test
    func fixedCompressionConveniencesMatchNativeConversionsAndBindThroughRawSQL() async throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let dense = EmbeddingVector<3>([0, 127.5, 255])
        let quantized = try dense.quantized8()
        let sparse = try dense.sparseFloat32()
        try await database.read { transaction throws -> Void in
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector8(dense, as: InlineQuantized8Vector<3>.self))",
              as: InlineQuantized8Vector<3>.self
            )
            .fetchOne(transaction) == quantized
          )
          #expect(
            try #sql(
              "SELECT \(TursoVec.vector32Sparse(dense, as: SizedSparseFloat32Vector<3>.self))",
              as: SizedSparseFloat32Vector<3>.self
            )
            .fetchOne(transaction) == sparse
          )
          #expect(
            try transaction.fetchOne("SELECT \(quantized)", as: InlineQuantized8Vector<3>.self)
              == quantized
          )
          #expect(
            try transaction.fetchOne("SELECT \(sparse)", as: SizedSparseFloat32Vector<3>.self)
              == sparse
          )
        }
      }
    }

    @Test
    func vectorFailuresRollBackWritesAndLeaveThePoolUsable() async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        try await database.write {
          try $0.execute("CREATE TABLE vectors (embedding F32_BLOB(3))")
        }
        let error = await #expect(throws: SQLiteError.self) {
          try await database.write { transaction in
            try #sql("INSERT INTO vectors VALUES (\(TursoVec.vector32("[1,2,3]")))")
              .execute(transaction)
            _ = try #sql(
              "SELECT \(TursoVec.distanceL2(TursoVec.vector32("[1,2,3]"), to: TursoVec.vector32("[1,2]")))",
              as: Double.self
            )
            .fetchOne(transaction)
          }
        }
        #expect(error?.message?.lowercased().contains("dimension") == true)
        #expect(
          try await database.read { try $0.fetchOne("SELECT count(*) FROM vectors", as: Int.self) }
            == 0
        )
        try await database.concurrentWrite {
          try #sql("INSERT INTO vectors VALUES (\(TursoVec.vector32("[1,2,3]")))").execute($0)
        }
        #expect(
          try await database.read {
            try #sql("SELECT embedding FROM vectors", as: [Float].VectorBytesRepresentation.self)
              .fetchOne($0)
          } == [1, 2, 3]
        )
      }
    }

    // Turso's native functions reject NULL, so `whenPresent` wraps them in CASE. These run the
    // guards in the engine against stored and bound NULLs. Unlike SQLiteVec, Turso reports a
    // zero-norm cosine as 1 rather than NULL.
    @Test
    func missingVectorsAndUndefinedDistancesDecodeAsNil() async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        try await database.write { transaction in
          try transaction.execute(
            "CREATE TABLE turso_nullable_embeddings (key INTEGER PRIMARY KEY, embedding F32_BLOB(2))"
          )
          try transaction.execute(
            """
            INSERT INTO turso_nullable_embeddings
            VALUES (1, vector32('[3,4]')), (2, NULL), (3, vector32('[0,0]'))
            """
          )
        }
        let candidate: [Float].VectorBytesRepresentation = [3, 4]
        let missing: [Float].VectorBytesRepresentation? = nil
        try await database.read { transaction in
          let rows = try TursoNullableEmbedding.order(by: \.key)
            .select { row in
              (
                row.embedding.whenPresent { TursoVec.extract($0) },
                row.embedding.whenPresent { TursoVec.distanceL2($0, to: candidate) },
                row.embedding.whenPresent { TursoVec.distanceCosine($0, to: candidate) }
              )
            }
            .fetchAll(transaction)
          #expect(rows.map(\.0) == ["[3,4]", nil, "[0,0]"])
          #expect(rows.map(\.1) == [0, nil, 5])
          let cosines = rows.map(\.2)
          #expect(abs(try #require(cosines[0])) < 1e-6)
          #expect(cosines[1] == nil)
          #expect(cosines[2] == 1)
          let fallbacks =
            try TursoNullableEmbedding.select {
              $0.embedding.whenPresent(missing) { TursoVec.distanceL2($0, to: $1) }
                .ifnull(Double(-1))
            }
            .fetchAll(transaction)
          #expect(fallbacks == [-1, -1, -1])
          #expect(
            try TursoNullableEmbedding
              .where {
                $0.embedding.whenPresent { TursoVec.distanceCosine($0, to: candidate) }.isNot(nil)
              }
              .select(\.key)
              .fetchAll(transaction) == [1, 3]
          )
          #expect(
            try #sql(
              "SELECT embedding FROM turso_nullable_embeddings ORDER BY key",
              as: [Float].VectorBytesRepresentation?.self
            )
            .fetchAll(transaction) == [[3, 4], nil, [0, 0]]
          )
        }
      }
    }

    // The helpers target Rust Turso. Keep the engine's unsupported libSQL functions explicit
    // using raw SQL; upstream intentionally provides no libSQL query helpers.
    @Test(arguments: ["vector16", "vectorb16", "vector_top_k"])
    func libSQLOnlyFunctionsReportEngineErrors(_ function: String) async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let query: SQL =
          function == "vector_top_k"
          ? "SELECT id FROM vector_top_k('embeddings_idx', '[1,2,3]', 2)"
          : "SELECT \(raw: function)('[1,2,3]')"
        let error = await #expect(throws: SQLiteError.self) {
          try await database.read { try $0.fetchOne(query, as: Int.self) }
        }
        #expect(error?.message?.contains(function) == true)
        #expect(error?.sql?.contains(function) == true)
      }
    }

    @Test
    func libSQLVectorIndexesReportEngineErrors() async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        try await database.write {
          try $0.execute(
            "CREATE TABLE turso_embeddings (key INTEGER PRIMARY KEY, title TEXT, embedding BLOB)"
          )
        }
        let error = await #expect(throws: SQLiteError.self) {
          try await database.write {
            try $0.execute(
              "CREATE INDEX embeddings_idx ON turso_embeddings (libsql_vector_idx(embedding, 'metric=l2'))"
            )
          }
        }
        #expect(error?.message?.contains("libsql_vector_idx") == true)
      }
    }
  }

  @Table("turso_embeddings")
  private struct TursoEmbedding {
    @Column(primaryKey: true)
    var key: Int
    var title: String
    @Column(as: [Float].VectorBytesRepresentation.self)
    var embedding: [Float]
  }

  @Table("turso_nullable_embeddings")
  private struct TursoNullableEmbedding {
    @Column(primaryKey: true)
    var key: Int
    @Column(as: [Float].VectorBytesRepresentation?.self)
    var embedding: [Float]?
  }

  @Table("turso_encoded_embeddings")
  private struct TursoEncodedEmbedding: Equatable {
    @Column(primaryKey: true)
    var key: Int
    @Column(as: [Double].TursoFloat64BytesRepresentation.self)
    var float64: [Double]
    var float8: Quantized8Vector
    @Column(as: [Bool].TursoBytesRepresentation.self)
    var bits: [Bool]
  }

  @Table("turso_sparse_embeddings")
  private struct TursoSparseEmbedding {
    @Column(primaryKey: true)
    var key: Int
    var embedding: SparseFloat32Vector
  }

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Table("turso_binary_embeddings")
  private struct TursoBinaryEmbedding {
    @Column(primaryKey: true)
    var key: Int
    @Column(as: BinaryEmbeddingVector<9>.TursoBytesRepresentation.self)
    var embedding: BinaryEmbeddingVector<9>
  }
#endif
