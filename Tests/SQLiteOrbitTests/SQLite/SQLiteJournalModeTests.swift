#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Suite
  struct SQLiteJournalModeTests {
    @Test
    func aJournalModeNameMustBeASingleWord() {
      var configuration = SQLiteConfiguration.default
      configuration.journalMode = SQLiteJournalMode(rawValue: "wal; DROP TABLE items")
      let error = #expect(throws: SQLiteError.self) {
        _ = try SQLiteQueue(path: .memory, configuration: configuration)
      }
      #expect(error?.primaryCode == .misuse)
    }

    #if !Turso
      @Test
      func aWritableConnectionSwitchesToTheModeBeforeTheConfigurationsSetups() async throws {
        try await withTestDatabaseFile { file in
          var configuration = SQLiteConfiguration.default
          configuration.journalMode = .wal
          do {
            let queue = try SQLiteQueue(path: file.path, configuration: configuration)
            #expect(try await journalMode(of: queue) == SQLiteJournalMode.wal.rawValue)
          }

          // A setup that changes the mode runs after it, and so has the last word. Leaving WAL
          // needs the only connection to the database, which the one above has closed.
          configuration.journalMode = .truncate
          configuration.setups = [.sql("PRAGMA journal_mode = DELETE")]
          let reopened = try SQLiteQueue(path: file.path, configuration: configuration)
          #expect(try await journalMode(of: reopened) == SQLiteJournalMode.delete.rawValue)
        }
      }

      @Test
      func noJournalModeLeavesTheDatabasesModeAlone() async throws {
        try await withTestDatabaseFile { file in
          var configuration = SQLiteConfiguration.default
          configuration.journalMode = .wal
          _ = try SQLiteQueue(path: file.path, configuration: configuration)

          let reopened = try SQLiteQueue(path: file.path, configuration: .default)
          #expect(try await journalMode(of: reopened) == SQLiteJournalMode.wal.rawValue)
        }
      }

      @Test
      func aReadOnlyConnectionNeitherAppliesTheModeNorFailsForIt() async throws {
        try await withTestDatabaseFile { file in
          let writer = try SQLiteSerialConnection(path: file.path, configuration: .default)
          try await writer.withWriteConnection { connection in
            try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
          }

          var configuration = SQLiteConfiguration.default
          configuration.journalMode = .wal
          let reader = try SQLiteSerialConnection(
            path: file.path,
            configuration: configuration,
            flags: [.readOnly, .noMutex]
          )
          let mode = try await reader.withReadConnection { connection in
            try connection.fetchOne("SELECT * FROM pragma_journal_mode") { $0[0].textValue ?? "" }
          }
          #expect(mode == SQLiteJournalMode.delete.rawValue)
        }
      }

      @Test
      func theModeIsSetWithTheDriversPrivilegeRatherThanTheApplicationsAuthorization()
        async throws
      {
        try await withTestDatabaseFile { file in
          var configuration = SQLiteConfiguration.default
          configuration.journalMode = .wal
          configuration.authorization = { authorization in
            if case .pragma(name: "journal_mode", value: .some) = authorization.action {
              return .deny
            }
            return .allow
          }
          let queue = try SQLiteQueue(path: file.path, configuration: configuration)
          #expect(try await journalMode(of: queue) == SQLiteJournalMode.wal.rawValue)
          await #expect(throws: SQLiteError.self) {
            try await queue.writeWithoutTransaction { connection in
              try connection.execute("PRAGMA journal_mode = DELETE")
            }
          }
        }
      }

      @Test
      func aPoolRunsInWALWhateverTheConfigurationAsksFor() async throws {
        try await withTestDatabaseFile { file in
          var configuration = SQLiteConfiguration.default
          configuration.journalMode = .delete
          let pool = try SQLitePool(path: file.path, configuration: configuration, readerCount: 1)
          #expect(try await journalMode(of: pool) == SQLiteJournalMode.wal.rawValue)
          let setupCount = try await pool.readWithoutTransaction { connection in
            connection.configuration.setups.count
          }
          #expect(setupCount == 0)
        }
      }

      @Test
      func aConnectionPoolsReadersAreQueryOnlyAndNeverApplyTheJournalMode() async throws {
        try await withTestDatabaseFile { file in
          var writerConfiguration = SQLiteConfiguration.default
          writerConfiguration.journalMode = .wal
          // A reader asked to switch the mode would fail to open, being read-only.
          var readerConfiguration = SQLiteConfiguration.default
          readerConfiguration.journalMode = .delete
          let pool = try SQLiteConnectionPool(
            path: file.path,
            readerConfiguration: readerConfiguration,
            writerConfiguration: writerConfiguration,
            readerCount: 1,
            writerSetups: [.sql("CREATE TABLE items (id INTEGER PRIMARY KEY)")]
          )
          #expect(pool.path == file.path)
          let (mode, isQueryOnly) = try await pool.withReadConnection { connection in
            (
              try connection.fetchOne("SELECT * FROM pragma_journal_mode") {
                $0[0].textValue ?? ""
              },
              try connection.fetchOne("PRAGMA query_only") { $0[0].integerValue }
            )
          }
          #expect(mode == SQLiteJournalMode.wal.rawValue)
          #expect(isQueryOnly == 1)
        }
      }
    #endif

    #if Turso
      @Test
      func aTursoPoolRunsInMVCCWithoutAddingToTheConfigurationsSetups() async throws {
        try await withTestDatabaseFile("turso") { file in
          let pool = try TursoPool(path: file.path)
          #expect(try await journalMode(of: pool)?.lowercased() == SQLiteJournalMode.mvcc.rawValue)
          let setupCount = try await pool.writeWithoutTransaction { connection in
            connection.configuration.setups.count
          }
          #expect(setupCount == 0)
        }
      }
    #endif
  }

  private func journalMode(of database: some OrbitDatabaseReader) async throws -> String? {
    try await database.readWithoutTransaction { connection in
      try connection.fetchOne("SELECT * FROM pragma_journal_mode") { $0[0].textValue ?? "" }
    }
  }
#endif
