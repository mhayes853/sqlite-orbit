#if BuiltInSQLite
  import SQLiteOrbit
  import Testing

  @Suite
  struct SQLiteAuthorizationTests {
    #if !Turso
      @Test
      func scopesReauthorizeCachedStatementsAndRestoreAfterFailure() throws {
        let database = try authorizationDatabase()
        try database.readBlocking { transaction in
          let value = try transaction.fetchOne(secretSQL) { $0[0].textValue }
          #expect(value == "private")
          let denied = #expect(throws: SQLiteError.self) {
            try transaction.withAuthorization(denySecrets) {
              try transaction.withAuthorization({ _ in .allow }) {
                try transaction.fetchOne(secretSQL) { $0[0].textValue }
              }
            }
          }
          #expect(denied?.primaryCode == .auth)
          #expect(throws: TestError.self) {
            try transaction.withAuthorization({ event in
              if case .read(table: "secrets", column: _) = event.action { return .ignore }
              return .allow
            }) {
              let values = try transaction.fetchAll(secretSQL) { $0[0] }
              #expect(values == [.null])
              throw TestError()
            }
          }
          #expect(try transaction.fetchOne(secretSQL) { $0[0].textValue } == "private")
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func configuredPolicyAppliesToReadersAndWriters(_ kind: SQLiteTestDriver) async throws {
        var configuration = SQLiteConfiguration.default
        configuration.authorization = denySecrets
        try await kind.withDatabase(configuration: configuration, readerCount: 2, schema: schema) {
          database in
          let read = await #expect(throws: SQLiteError.self) {
            try await database.read { transaction in
              try transaction.withAuthorization({ _ in .allow }) {
                try transaction.fetchOne(secretSQL) { $0[0].textValue }
              }
            }
          }
          #expect(read?.primaryCode == .auth)
          let write = await #expect(throws: SQLiteError.self) {
            try await database.write { transaction in
              try transaction.execute("INSERT INTO copies SELECT value FROM secrets")
            }
          }
          #expect(write?.primaryCode == .auth)
          let count = try await database.read {
            try $0.fetchOne("SELECT count(*) FROM copies") { $0[0].integerValue }
          }
          #expect(count == 0)
        }
      }

      @Test
      func replacingThePersistentPolicyInvalidatesCachedStatements() throws {
        var configuration = SQLiteConfiguration.default
        configuration.setups.append(
          SQLiteSetup { connection in
            try connection.setAuthorization(denySecrets)
          }
        )
        configuration.setups.append(.script(schema))
        let database = try SQLiteQueue(path: .memory, configuration: configuration)
        try database.writeWithoutTransactionBlocking { connection in
          #expect(throws: SQLiteError.self) {
            try connection.fetchOne(secretSQL) { $0[0].textValue }
          }
          try connection.setAuthorization(nil)
          #expect(try connection.fetchOne(secretSQL) { $0[0].textValue } == "private")
          try connection.setAuthorization(denySecrets)
          #expect(throws: SQLiteError.self) {
            try connection.fetchOne(secretSQL) { $0[0].textValue }
          }
          try connection.withAuthorization({ _ in .allow }) {
            _ = #expect(throws: SQLiteError.self) { try connection.setAuthorization(nil) }
          }
        }
        try database.readWithoutTransactionBlocking { connection in
          #expect(throws: SQLiteError.self) {
            try connection.fetchOne(secretSQL) { $0[0].textValue }
          }
          try connection.setAuthorization(nil)
          let value = try connection.withAuthorization({ _ in .allow }) {
            try connection.fetchOne(secretSQL) { $0[0].textValue }
          }
          #expect(value == "private")
        }
      }

      @Test(arguments: [false, true])
      func outstandingCursorsPreventPolicyChanges(cached: Bool) throws {
        let database = try authorizationDatabase()
        try database.writeWithoutTransactionBlocking { connection in
          var cursor = try connection.rowCursor(secretSQL, cached: cached)
          let error = #expect(throws: SQLiteError.self) {
            try connection.withAuthorization(denySecrets) { Issue.record("The scope ran") }
          }
          #expect(error?.primaryCode == .misuse)
          #expect(throws: SQLiteError.self) { try connection.setAuthorization(denySecrets) }
          #expect(try cursor.next()?[0].textValue == "private")
        }
      }

      @Test
      func deniedCommitStillRollsBackAndReleasesTheConnection() throws {
        var configuration = SQLiteConfiguration.default
        configuration.authorization = { event in
          switch event.action {
          case .transaction(operation: "COMMIT"), .transaction(operation: "ROLLBACK"): return .deny
          default: return .allow
          }
        }
        configuration.setups.append(.script(schema))
        let database = try SQLiteQueue(path: .memory, configuration: configuration)
        let error = #expect(throws: SQLiteError.self) {
          try database.writeBlocking { try $0.execute("INSERT INTO copies VALUES ('lost')") }
        }
        #expect(error?.primaryCode == .auth)
        let count = try database.readBlocking {
          try $0.fetchOne("SELECT count(*) FROM copies") { $0[0].integerValue }
        }
        #expect(count == 0)
      }

      @Test(arguments: ["BEGIN", "COMMIT", "query_only", "foreign_keys"])
      func ignoringManagedControlFailsInsteadOfSilentlySkippingIt(action: String) throws {
        var configuration = SQLiteConfiguration.default
        configuration.setups.append(.script(schema))
        configuration.authorization = { event in
          switch event.action {
          case .transaction(operation: action), .pragma(name: action, value: _): return .ignore
          default: return .allow
          }
        }
        let database = try SQLiteQueue(path: .memory, configuration: configuration)
        let ran = TestCounter()
        let error = #expect(throws: SQLiteError.self) {
          if action == "query_only" {
            try database.readBlocking { _ in _ = ran.increment() }
          } else if action == "foreign_keys" {
            try database.writeWithoutTransactionBlocking { connection in
              try connection.setForeignKeysEnabled(false)
              try connection.execute("INSERT INTO copies VALUES ('lost')")
            }
          } else {
            try database.writeBlocking { transaction in
              ran.increment()
              try transaction.execute("INSERT INTO copies VALUES ('lost')")
            }
          }
        }
        #expect(error?.primaryCode == .auth)
        #expect(ran.value == (action == "COMMIT" ? 1 : 0))
        try database.writeWithoutTransactionBlocking { connection in
          try connection.setAuthorization(nil)
          #expect(
            try connection.fetchOne("SELECT count(*) FROM copies") { $0[0].integerValue } == 0
          )
        }
      }

      @Test(arguments: ["journal_mode", "query_only"])
      func ignoredPoolSetupFailsToOpen(pragma: String) throws {
        var configuration = SQLiteConfiguration.default
        configuration.authorization = { event in
          if case .pragma(name: pragma, value: _) = event.action { return .ignore }
          return .allow
        }
        try withTestDatabaseFile { file in
          let error = #expect(throws: SQLiteError.self) {
            try file.open(.pool, configuration: configuration, readerCount: 1)
          }
          #expect(error?.primaryCode == .auth)
        }
      }

      @Test
      func eventsExposeViewAndFunctionDetailsAndPreserveReadRestrictions() throws {
        let database = try authorizationDatabase()
        let events = TestRecorder<SQLiteAuthorization>()
        try database.readBlocking { transaction in
          try transaction.withAuthorization({ event in
            events.append(event)
            return .allow
          }) {
            let value = try transaction.fetchOne("SELECT upper(value) FROM visible_secrets") {
              $0[0].textValue
            }
            #expect(value == "PRIVATE")
            _ = #expect(throws: SQLiteError.self) {
              try transaction.fetchOne("DELETE FROM secrets RETURNING value") { $0[0].textValue }
            }
          }
        }
        let recorded = events.values
        #expect(
          recorded.contains(
            SQLiteAuthorization(
              action: .read(table: "secrets", column: "value"),
              schemaName: "main",
              sourceName: "visible_secrets"
            )
          )
        )
        #expect(recorded.contains { $0.action == .function(name: "upper") })
      }

      private func authorizationDatabase() throws -> SQLiteQueue {
        var configuration = SQLiteConfiguration.default
        configuration.setups.append(.script(schema))
        return try SQLiteQueue(path: .memory, configuration: configuration)
      }
    #endif

    @Test
    func missingBackendSupportFailsConfigurationAndScopeEntry() throws {
      var configuration = SQLiteConfiguration.default
      configuration.library.authorizer = nil
      configuration.authorization = { _ in .allow }
      #expect(throws: SQLiteFeatureUnavailableError.self) {
        try SQLiteQueue(path: .memory, configuration: configuration)
      }
      configuration.authorization = nil
      let database = try SQLiteQueue(path: .memory, configuration: configuration)
      try database.readBlocking { transaction in
        _ = #expect(throws: SQLiteFeatureUnavailableError.self) {
          try transaction.withAuthorization({ _ in .allow }) { Issue.record("The scope ran") }
        }
      }
    }
  }

  private let secretSQL: SQL = "SELECT value FROM secrets"
  private let denySecrets: SQLiteAuthorizationHandler = { event in
    if case .read(table: "secrets", column: _) = event.action { return .deny }
    return .allow
  }
  private let schema = """
    CREATE TABLE secrets (value TEXT);
    INSERT INTO secrets VALUES ('private');
    CREATE TABLE copies (value TEXT);
    CREATE VIEW visible_secrets AS SELECT value FROM secrets;
    """
#endif
