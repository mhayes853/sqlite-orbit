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
      configuration.readerCount = 2
      configuration.connectionSetups.append(
        SQLiteConnectionSetup { connection in
          try connection.execute("SELECT vector_extract(vector32('[1,2,3]'))")
          setups.increment()
          return SQLiteResultCode.ok.rawValue
        }
      )
      try await withTestDatabaseFile("turso-vectors") { file in
        for _ in 0..<2 {
          let database = try file.tursoPool(configuration: configuration, writerCount: 2)
          #expect(
            try await database.read {
              try $0.fetchOne(
                #sql("SELECT \(TursoVec.extract(TursoVec.vector32("[1,2,3]")))", as: String.self)
              )
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
        let float64: [Double].VectorBytesRepresentation = [1, -2, 0.5]
        try await database.read { transaction in
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector32("[1,-2,0.5]"))",
                as: [Float].VectorBytesRepresentation.self
              )
            )
              == float32.queryOutput
          )
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector("[1,-2,0.5]"))",
                as: [Float].VectorBytesRepresentation.self
              )
            )
              == float32.queryOutput
          )
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector64("[1,-2,0.5]"))",
                as: [Double].VectorBytesRepresentation.self
              )
            )
              == float64.queryOutput
          )
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector32(float64))",
                as: [Float].VectorBytesRepresentation.self
              )
            )
              == float32.queryOutput
          )
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector64(float32))",
                as: [Double].VectorBytesRepresentation.self
              )
            )
              == float64.queryOutput
          )
          let bytes = try transaction.fetchOne(
            #sql("SELECT \(TursoVec.vector32("[1,-2,0.5]"))", as: [UInt8].self)
          )
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
          let decodedVector = try transaction.fetchOne(
            #sql("SELECT \(TursoVec.vector8(json))", as: Quantized8Vector.self)
          )
          let encoded = try #require(decodedVector)
          #expect(encoded == float8)
          #expect(encoded.vectorBytes == float8.vectorBytes)
          let decoded = encoded.decodedValues()
          #expect(decoded.count == dimensions)
          for (actual, expected) in zip(decoded, values) {
            #expect(abs(actual - expected) <= Float(max(1, dimensions - 1) * 10) / 255)
          }
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector1bit(binaryJSON))",
                as: [Bool].TursoBytesRepresentation.self
              )
            ) == bits
          )
          #expect(
            try transaction.fetchOne(#sql("SELECT \(TursoVec.extract(binary))", as: String.self))
              == binaryJSON
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(TursoVec.distanceCosine(binary, to: binary))", as: Double.self)
            )
              == 0
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(TursoVec.distanceCosine(binary, to: opposite))", as: Double.self)
            ) == Double(dimensions)
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(TursoVec.distanceDot(binary, to: binary))", as: Double.self)
            ) == -Double(dimensions)
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(TursoVec.distanceDot(binary, to: opposite))", as: Double.self)
            ) == Double(dimensions)
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(TursoVec.distanceJaccard(binary, to: opposite))", as: Double.self)
            ) == 1
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(TursoVec.distanceL2(float8, to: float8))", as: Double.self)
            )
              == 0
          )
          let convertedVector = try transaction.fetchOne(
            #sql(
              "SELECT \(TursoVec.vector32(float8))",
              as: [Float].VectorBytesRepresentation.self
            )
          )
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
          let left: [Double].VectorBytesRepresentation = [1, 0, 0]
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
          try $0.fetchOne(
            #sql(
              "SELECT \(distances.joined(separator: ", "))",
              as: (Double, Double, Double, Double).self
            )
          )
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
          try transaction.execute(
            TursoSparseEmbedding.insert { TursoSparseEmbedding(key: 1, embedding: sparse) }
          )
          try transaction.execute(
            TursoSparseEmbedding.insert {
              ($0.key, $0.embedding)
            } values: {
              (2, TursoVec.vector32Sparse(json))
            }
          )
        }
        try await database.read { transaction in
          let rows = try transaction.fetchAll(TursoSparseEmbedding.order(by: \.key))
          #expect(rows.map(\.embedding) == [sparse, sparse])
          let bytes = try transaction.fetchOne(
            #sql("SELECT \(TursoVec.vector32Sparse(json))", as: [UInt8].self)
          )
          #expect(sparse.queryBinding == bytes.map { .blob($0) })
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector32(sparse))",
                as: [Float].VectorBytesRepresentation.self
              )
            ) == values
          )
          let sliced = try transaction.fetchOne(
            #sql("SELECT \(TursoVec.slice(sparse, from: 2, to: 8))", as: SparseFloat32Vector.self)
          )
          #expect(sliced?.denseValues() == Array(values[2..<8]))
          if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            #expect(
              try transaction.fetchOne(
                #sql(
                  "SELECT \(TursoVec.vector32Sparse(json, as: SizedSparseFloat32Vector<9>.self))",
                  as: SizedSparseFloat32Vector<9>.self
                )
              ) == SizedSparseFloat32Vector<9>(compressing: EmbeddingVector<9> { values[$0] })
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
        let double: [Double].VectorBytesRepresentation = [Double.pi, -2]
        try await database.read { transaction throws -> Void in
          let joined = TursoVec.concat(left, TursoVec.vector32("[0,4]"))
          let joinedDouble = TursoVec.concat(double, TursoVec.vector64("[0,4]"))
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(joined)", as: [Float].VectorBytesRepresentation.self)
            ) == [1, -2, 0, 4]
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(joinedDouble)", as: [Double].VectorBytesRepresentation.self)
            ) == [Double.pi, -2, 0, 4]
          )
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.slice(joined, from: 1, to: 3))",
                as: [Float].VectorBytesRepresentation.self
              )
            ) == [-2, 0]
          )
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.slice(joinedDouble, from: 1, to: 3))",
                as: [Double].VectorBytesRepresentation.self
              )
            ) == [-2, 0]
          )
          if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            #expect(
              try transaction.fetchOne(
                #sql(
                  "SELECT \(TursoVec.concat(left, TursoVec.vector32("[0,4]"), as: EmbeddingVector<4>.self))",
                  as: EmbeddingVector<4>.self
                )
              ) == EmbeddingVector<4> { [Float(1), -2, 0, 4][$0] }
            )
            #expect(
              try transaction.fetchOne(
                #sql(
                  "SELECT \(TursoVec.slice(joinedDouble, from: 1, to: 3, as: EmbeddingVector64<2>.VectorBytesRepresentation.self))",
                  as: EmbeddingVector64<2>.VectorBytesRepresentation.self
                )
              ) == EmbeddingVector64<2> { [Double(-2), 0][$0] }
            )
            #expect(throws: VectorDecodingError.dimensionMismatch(expected: 3, actual: 2)) {
              try transaction.fetchOne(
                #sql(
                  "SELECT \(TursoVec.slice(joined, from: 1, to: 3, as: EmbeddingVector<3>.self))",
                  as: EmbeddingVector<3>.self
                )
              )
            }
          }
        }
        // The native engine can abort a transaction on an invalid slice. Inspect the original
        // error without a transaction, then verify that the pool can still execute the helper.
        let error = await #expect(throws: SQLiteError.self) {
          try await database.readWithoutTransaction {
            let joined = TursoVec.concat(left, TursoVec.vector32("[0,4]"))
            return try $0.fetchOne(
              #sql(
                "SELECT \(TursoVec.slice(joined, from: 0, to: 5))",
                as: [Float].VectorBytesRepresentation.self
              )
            )
          }
        }
        #expect(error?.message?.contains("out of bounds") == true)
        #expect(error?.sql?.contains("vector_slice") == true)
        let reloaded = try await database.read {
          let joined = TursoVec.concat(left, TursoVec.vector32("[0,4]"))
          return try $0.fetchOne(
            #sql("SELECT \(joined)", as: [Float].VectorBytesRepresentation.self)
          )
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
            try transaction.execute(
              TursoEmbedding.insert {
                ($0.key, $0.title, $0.embedding)
              } values: {
                (key, title, TursoVec.vector32(json))
              }
            )
          }
        }
        let vector: [Float].VectorBytesRepresentation = [1, 0, 0]
        let rows = try await database.read { transaction in
          try transaction.fetchAll(
            TursoEmbedding.order { TursoVec.distanceCosine($0.embedding, to: vector).asc() }
              .select {
                (
                  $0.title, TursoVec.extract($0.embedding),
                  TursoVec.distanceCosine($0.embedding, to: vector),
                  TursoVec.distanceL2($0.embedding, to: TursoVec.vector32("[1,0,0]"))
                )
              }
          )
        }
        #expect(rows.map(\.0) == ["nearest", "neighbor", "opposite"])
        #expect(rows.map(\.1) == ["[1,0,0]", "[1,1,0]", "[-1,0,0]"])
        #expect(abs(rows[0].2) < 1e-6)
        #expect(abs(rows[1].2 - (1 - 1 / Double(2).squareRoot())) < 1e-6)
        #expect(abs(rows[2].2 - 2) < 1e-6)
        #expect(rows.map(\.3) == [0, 1, 2])
        #expect(
          try await database.read {
            try $0.fetchAll(
              TursoEmbedding.order { TursoVec.distanceCosine($0.embedding, to: vector).asc() }
                .limit(2).select(\.title)
            )
          } == ["nearest", "neighbor"]
        )
        #expect(
          try await database.read {
            try $0.fetchAll(
              TursoEmbedding.where { TursoVec.distanceL2($0.embedding, to: vector).lt(1.5) }
                .order(by: \.key).select(\.title)
            )
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
          try transaction.execute(TursoEncodedEmbedding.insert { row })
          try transaction.execute(
            TursoEncodedEmbedding.insert {
              ($0.key, $0.float64, $0.float8, $0.bits)
            } values: {
              (
                2, TursoVec.vector64("[1,-2,0.5]"), TursoVec.vector8("[0,127,255]"),
                TursoVec.vector1bit("[1,-1,1]")
              )
            }
          )
        }
        try await database.read { transaction in
          let rows = try transaction.fetchAll(TursoEncodedEmbedding.order(by: \.key))
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
          let double = [Double].VectorBytesRepresentation(queryOutput: row.float64)
          let float8 = row.float8
          let binary = [Bool].TursoBytesRepresentation(queryOutput: row.bits)
          let distances = try transaction.fetchAll(
            TursoEncodedEmbedding.select {
              (
                TursoVec.distanceL2($0.float64, to: double),
                TursoVec.distanceCosine($0.float8, to: float8),
                TursoVec.distanceCosine($0.bits, to: binary), TursoVec.extract($0.bits)
              )
            }
          )
          #expect(distances.count == 2)
          for distance in distances {
            #expect(abs(distance.0) < 1e-6)
            #expect(abs(distance.1) < 1e-6)
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
          let rows = try transaction.fetchAll(
            #sql(
              "SELECT * FROM encoded_values",
              as: (
                Quantized8Vector, SparseFloat32Vector, InlineQuantized8Vector<3>,
                SizedSparseFloat32Vector<6>
              )
              .self
            )
          )
          #expect(rows.count == 2)
          for row in rows {
            #expect(row.0.vectorBytes == quantized.vectorBytes)
            #expect(row.1.vectorBytes == sparse.vectorBytes)
            #expect(row.2.vectorBytes == inline.vectorBytes)
            #expect(row.3.vectorBytes == sized.vectorBytes)
          }
          #expect(
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector8("[0,127,255]", as: InlineQuantized8Vector<3>.self))",
                as: InlineQuantized8Vector<3>.self
              )
            )
              == InlineQuantized8Vector<3>(
                quantizing: EmbeddingVector<3> { [Float(0), 127, 255][$0] }
              )
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(TursoVec.distanceL2(inline, to: quantized))", as: Double.self)
            ) == 0
          )
          #expect(
            try transaction.fetchOne(
              #sql("SELECT \(TursoVec.distanceL2(sized, to: sparse))", as: Double.self)
            ) == 0
          )
          #expect(throws: VectorDecodingError.dimensionMismatch(expected: 2, actual: 3)) {
            try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.vector8("[0,127,255]", as: InlineQuantized8Vector<2>.self))",
                as: InlineQuantized8Vector<2>.self
              )
            )
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
        let binary = BinaryEmbeddingVector<3> { $0 != 1 }
        try await database.write { transaction in
          try transaction.execute(
            "CREATE TABLE vectors (embedding F32_BLOB(3), float64 F64_BLOB(3))"
          )
          try transaction.execute("INSERT INTO vectors VALUES (\(vector), \(double))")
        }
        try await database.read { transaction in
          let stored = try transaction.fetchOne(
            "SELECT embedding FROM vectors",
            as: EmbeddingVector<3>.self
          )
          let storedDouble = try transaction.fetchOne(
            "SELECT float64 FROM vectors",
            as: EmbeddingVector64<3>.self
          )
          let nativeDouble = try transaction.fetchOne(
            "SELECT vector64('[1,-2,0.5]')",
            as: EmbeddingVector64<3>.self
          )
          let float32 = try transaction.fetchOne(
            #sql(
              "SELECT \(TursoVec.vector32(vector, as: EmbeddingVector<3>.self))",
              as: EmbeddingVector<3>.self
            )
          )
          let float64 = try transaction.fetchOne(
            #sql(
              "SELECT \(TursoVec.vector64(vector, as: EmbeddingVector64<3>.VectorBytesRepresentation.self))",
              as: EmbeddingVector64<3>.VectorBytesRepresentation.self
            )
          )
          let bits = try transaction.fetchOne(
            #sql(
              "SELECT \(TursoVec.vector1bit("[1,-1,1]", as: BinaryEmbeddingVector<3>.TursoBytesRepresentation.self))",
              as: BinaryEmbeddingVector<3>.TursoBytesRepresentation.self
            )
          )
          #expect(stored == vector)
          #expect(storedDouble == double)
          #expect(nativeDouble == double)
          #expect(float32 == vector)
          #expect(float64 == double)
          #expect(bits == binary)
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
            try transaction.execute(
              #sql("INSERT INTO vectors VALUES (\(TursoVec.vector32("[1,2,3]")))")
            )
            _ = try transaction.fetchOne(
              #sql(
                "SELECT \(TursoVec.distanceL2(TursoVec.vector32("[1,2,3]"), to: TursoVec.vector32("[1,2]")))",
                as: Double.self
              )
            )
          }
        }
        #expect(error?.message?.lowercased().contains("dimension") == true)
        #expect(
          try await database.read { try $0.fetchOne("SELECT count(*) FROM vectors", as: Int.self) }
            == 0
        )
        try await database.concurrentWrite {
          try $0.execute(#sql("INSERT INTO vectors VALUES (\(TursoVec.vector32("[1,2,3]")))"))
        }
        #expect(
          try await database.read {
            try $0.fetchOne(
              #sql("SELECT embedding FROM vectors", as: [Float].VectorBytesRepresentation.self)
            )
          } == [1, 2, 3]
        )
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

  @Table("turso_encoded_embeddings")
  private struct TursoEncodedEmbedding: Equatable {
    @Column(primaryKey: true)
    var key: Int
    @Column(as: [Double].VectorBytesRepresentation.self)
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
#endif
