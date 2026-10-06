#if Vectors && BuiltInSQLite && !Turso
  import Testing
  @testable import SQLiteOrbit

  @Suite
  struct SQLiteVecTests {
    @Test
    func vectorTableObservationSeesCommittedChangesAndIgnoresRollback() throws {
      let database = try SQLiteQueue(path: ":memory:")
      try database.writeBlocking {
        try $0.execute("CREATE VIRTUAL TABLE embeddings USING vec0(embedding float[3])")
      }
      let values = TestRecorder<Int64>()
      let errors = TestCounter()
      let subscription = try OrbitValueObservation<Int64>
        .tracking { transaction in
          try transaction.fetchOne("SELECT count(*) FROM embeddings", as: Int64.self) ?? 0
        }
        .subscribe(
          to: database,
          scheduling: .immediate,
          onError: { _ in errors.increment() },
          onChange: { change in values.append(change.value) }
        )
      try database.writeBlocking {
        try $0.execute("INSERT INTO embeddings VALUES (1, vec_f32('[1,2,3]'))")
      }
      #expect(throws: TestError()) {
        try database.writeBlocking {
          try $0.execute("INSERT INTO embeddings VALUES (2, vec_f32('[2,3,4]'))")
          throw TestError()
        }
      }
      #expect(values.values == [0, 1])
      #expect(errors.value == 0)
      subscription.cancel()
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func defaultConnectionsCanQueryVectorsAndRollBack(_ driver: SQLiteTestDriver) async throws {
      try await driver.withDatabase(
        schema: "CREATE VIRTUAL TABLE embeddings USING vec0(embedding float[3])"
      ) { database in
        let version = try await database.read {
          try $0.fetchOne("SELECT vec_version()", as: String.self)
        }
        #expect(try #require(version).hasPrefix("v0."))

        try await database.write {
          try $0.executeScript(
            """
            INSERT INTO embeddings(rowid, embedding) VALUES
              (1, vec_f32('[0,0,0]')),
              (2, vec_f32('[1,0,0]')),
              (3, vec_f32('[2,0,0]'));
            """
          )
        }
        let nearest = try await database.read {
          try $0.fetchAll(
            """
            SELECT rowid FROM embeddings
            WHERE embedding MATCH vec_f32('[0.1,0,0]') AND k = 2
            ORDER BY distance
            """,
            as: Int64.self
          )
        }
        #expect(nearest == [1, 2])

        await #expect(throws: TestError()) {
          try await database.write {
            try $0.execute("INSERT INTO embeddings VALUES (4, vec_f32('[4,0,0]'))")
            throw TestError()
          }
        }
        #expect(
          try await database.read {
            try $0.fetchOne("SELECT count(*) FROM embeddings", as: Int64.self)
          } == 3
        )
      }
    }

    @Test
    func everyPoolConnectionHasVecBeforeUserSetupAndAfterReopening() async throws {
      let setups = TestCounter()
      var configuration = SQLiteConfiguration.default
      configuration.connectionSetups.append(
        SQLiteConnectionSetup { connection in
          // Vec must already be present in both the writer and each reader.
          try connection.execute("SELECT vec_version()")
          setups.increment()
          return SQLiteResultCode.ok.rawValue
        }
      )
      try await withTestDatabaseFile { file in
        for _ in 0..<2 {
          let pool = try file.pool(configuration: configuration, readerCount: 3)
          #expect(
            try await pool.read {
              try $0.fetchOne("SELECT vec_length('[1,2,3]')", as: Int64.self)
            } == 3
          )
        }
      }
      #expect(setups.value == 8)
    }

    @Test
    func unsupportedRuntimeFailsBeforeOpeningEvenWithASystemName() throws {
      let opens = TestCounter()
      var configuration = SQLiteConfiguration.default
      configuration.library.name = "system SQLite"
      configuration.library.extensions = nil
      configuration.library.connections.open = { _, _, _, _ in
        opens.increment()
        return SQLiteResultCode.ok.rawValue
      }
      #expect(
        throws: SQLiteFeatureUnavailableError(libraryName: "system SQLite", feature: .sqliteVec)
      ) {
        _ = try SQLiteQueue(path: ":memory:", configuration: configuration)
      }
      #expect(opens.value == 0)
    }

    @Test
    func failedRegistrationPreventsOpeningAndUsesTheCurrentLibrary() throws {
      let opens = TestCounter()
      let registrations = TestCounter()
      var configuration = SQLiteConfiguration.default
      configuration.library.extensions = SQLiteLibrary.Extensions(
        autoExtensions: SQLiteLibrary.AutoExtensions(
          register: { _ in
            registrations.increment()
            return SQLiteResultCode.busy.rawValue
          },
          cancel: { _ in 0 }
        )
      )
      configuration.library.connections.open = { _, _, _, _ in
        opens.increment()
        return SQLiteResultCode.ok.rawValue
      }
      let error = #expect(throws: SQLiteError.self) {
        _ = try SQLiteQueue(path: ":memory:", configuration: configuration)
      }
      #expect(error?.code == .busy)
      #expect(registrations.value == 1)
      #expect(opens.value == 0)
    }

    #if !canImport(Darwin)
      @Test
      func initializerRejectsAMissingAPITableWithoutCallingVec() throws {
        var configuration = SQLiteConfiguration.default
        configuration.library.extensions = SQLiteLibrary.Extensions(
          autoExtensions: SQLiteLibrary.AutoExtensions(
            register: { initializer in
              let callback = unsafeBitCast(initializer, to: SQLiteExtensionInitializer.self)
              return callback(nil, nil, nil)
            },
            cancel: { _ in 0 }
          )
        )
        let error = #expect(throws: SQLiteError.self) {
          _ = try SQLiteQueue(path: ":memory:", configuration: configuration)
        }
        #expect(error?.code == .error)
      }

    #endif

    #if canImport(Darwin) && SystemSQLite
      @Test
      func appleSystemInitializationDoesNotDependOnItsDiagnosticName() throws {
        var configuration = SQLiteConfiguration.default
        configuration.library.name = "renamed system library"
        #expect(configuration.library.extensions?.autoExtensions == nil)
        let database = try SQLiteQueue(path: ":memory:", configuration: configuration)
        #expect(
          try database.readBlocking {
            try $0.fetchOne("SELECT vec_length('[1,2,3]')", as: Int64.self)
          } == 3
        )
      }
    #endif
  }
#endif
