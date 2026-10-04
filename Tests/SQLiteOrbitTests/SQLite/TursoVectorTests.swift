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
        let float8 = [Float].Float8Representation(queryOutput: values)
        let bits = (0..<dimensions).map { $0.isMultiple(of: 2) }
        let binary = [Bool].TursoBytesRepresentation(queryOutput: bits)
        let opposite = [Bool].TursoBytesRepresentation(queryOutput: bits.map { !$0 })
        let json = "[" + values.map(String.init(describing:)).joined(separator: ",") + "]"
        let binaryJSON = "[" + bits.map { $0 ? "1" : "-1" }.joined(separator: ",") + "]"
        try await database.read { transaction in
          let decodedVector = try transaction.fetchOne(
            #sql("SELECT \(TursoVec.vector8(json))", as: [Float].Float8Representation.self)
          )
          let decoded = try #require(decodedVector)
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

    @Test
    func structuredInsertsAndColumnHelpersSearchRealRows() async throws {
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
            TursoEmbedding.order { $0.embedding.distanceCosine(to: vector).asc() }
              .select {
                (
                  $0.title, $0.embedding.toJSON(), $0.embedding.distanceCosine(to: vector),
                  $0.embedding.distanceL2(to: "[1,0,0]")
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
              TursoEmbedding.order { $0.embedding.distanceCosine(to: vector).asc() }
                .limit(2).select(\.title)
            )
          } == ["nearest", "neighbor"]
        )
        #expect(
          try await database.read {
            try $0.fetchAll(
              TursoEmbedding.where { $0.embedding.distanceL2(to: vector).lt(1.5) }
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
          float8: [0, 127, 255],
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
          let float8 = [Float].Float8Representation(queryOutput: row.float8)
          let binary = [Bool].TursoBytesRepresentation(queryOutput: row.bits)
          let distances = try transaction.fetchAll(
            TursoEncodedEmbedding.select {
              (
                $0.float64.distanceL2(to: double), $0.float8.distanceCosine(to: float8),
                $0.bits.distanceCosine(to: binary), $0.bits.toJSON()
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
    func fixedSizeVectorsWorkWithTypedHelpersAndRawSQL() async throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let vector = EmbeddingVector<3> { [Float(1), -2, 0.5][$0] }
        let double = EmbeddingVector64<3> { Double(vector[$0]) }
        let half = EmbeddingVector16<3> { Float16(vector[$0]) }
        let binary = BinaryEmbeddingVector<3> { $0 != 1 }
        try await database.write { transaction in
          try transaction.execute(
            "CREATE TABLE vectors (embedding F32_BLOB(3), float64 F64_BLOB(3), float16 BLOB)"
          )
          try transaction.execute("INSERT INTO vectors VALUES (\(vector), \(double), \(half))")
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
          let storedHalf = try transaction.fetchOne(
            "SELECT float16 FROM vectors",
            as: EmbeddingVector16<3>.self
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
          #expect(storedHalf == half)
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
              #sql("SELECT \(TursoVec.distanceL2("[1,2,3]", to: "[1,2]"))", as: Double.self)
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

    // The Rust engine bundled by Orbit is distinct from Turso Cloud/libSQL. Keep its current
    // unsupported helpers explicit, executing their SQL rather than merely checking SQL strings.
    @Test(arguments: ["vector16", "vectorb16", "vector_top_k"])
    func libSQLOnlyFunctionsReportEngineErrors(_ function: String) async throws {
      try await withTestDatabaseFile("turso-vectors") { file in
        let database = try file.tursoPool()
        let expression: QueryFragment
        switch function {
        case "vector16": expression = TursoVec.vector16("[1,2,3]").queryFragment
        case "vectorb16": expression = TursoVec.vectorb16("[1,2,3]").queryFragment
        default:
          expression = TursoVec.topK(index: "embeddings_idx", vector: "[1,2,3]", k: 2).query
        }
        let query = function == "vector_top_k" ? expression : "SELECT \(expression)"
        let error = await #expect(throws: SQLiteError.self) {
          try await database.read { try $0.fetchOne(#sql("\(query)", as: Void.self)) }
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
            let marker = TursoVec.index(TursoEmbedding.columns.embedding, settings: ["metric=l2"])
            try $0.execute(#sql("CREATE INDEX embeddings_idx ON turso_embeddings (\(marker))"))
          }
        }
        #expect(error?.message?.contains("libsql_vector_idx") == true)
      }
    }
  }

  @Table("turso_embeddings")
  private struct TursoEmbedding: TursoVectorTable {
    @Column(primaryKey: true)
    var key: Int
    var title: String
    @Column(as: [Float].VectorBytesRepresentation.self)
    var embedding: [Float]
  }

  @Table("turso_encoded_embeddings")
  private struct TursoEncodedEmbedding: Equatable, TursoVectorTable {
    @Column(primaryKey: true)
    var key: Int
    @Column(as: [Double].VectorBytesRepresentation.self)
    var float64: [Double]
    @Column(as: [Float].Float8Representation.self)
    var float8: [Float]
    @Column(as: [Bool].TursoBytesRepresentation.self)
    var bits: [Bool]
  }
#endif
