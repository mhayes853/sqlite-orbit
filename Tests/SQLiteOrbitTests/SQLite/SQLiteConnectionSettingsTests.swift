#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Foundation
    import Testing

    @testable import SQLiteOrbit

    @Suite
    struct SQLiteConnectionSettingsTests {
      // MARK: - Busy timeout

      @Test(arguments: SQLiteTestDriver.allCases)
      func busyTimeoutChangedByAWriteConnectionIsRestoredWhenTheAccessEnds(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(readerCount: 1) { driver in
          let during = try await driver.writeWithoutTransaction { connection in
            #expect(connection.busyTimeout == .limit(.seconds(5)))
            try connection.setBusyTimeout(.limit(.seconds(42)))
            #expect(connection.busyTimeout == .limit(.seconds(42)))
            return try connection.fetchOne(busyTimeout)
          }
          #expect(during == 42_000)

          let after = try await driver.writeWithoutTransaction { connection in
            #expect(connection.busyTimeout == .limit(.seconds(5)))
            return try connection.fetchOne(busyTimeout)
          }
          #expect(after == 5000)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func busyTimeoutChangedByAReadConnectionIsRestoredWhenTheAccessEnds(
        _ kind: SQLiteTestDriver
      ) async throws {
        // One reader, so that every read lands on the connection the first one changed.
        try await kind.withDatabase(readerCount: 1) { driver in
          let during = try await driver.readWithoutTransaction { connection in
            try connection.setBusyTimeout(.maximum)
            #expect(connection.busyTimeout == .maximum)
            return try connection.fetchOne(busyTimeout)
          }
          #expect(during == Int(Int32.max))
          #expect(try await driver.read { try $0.fetchOne(busyTimeout) } == 5000)

          // A body that throws has its change put back all the same.
          await #expect(throws: TestError()) {
            try await driver.readWithoutTransaction { connection in
              try connection.setBusyTimeout(.limit(.milliseconds(1)))
              throw TestError()
            }
          }
          let after = try await driver.readWithoutTransaction { connection in
            #expect(connection.busyTimeout == .limit(.seconds(5)))
            return try connection.fetchOne(busyTimeout)
          }
          #expect(after == 5000)
        }
      }

      @Test(arguments: [false, true])
      func busyTimeoutFailuresThrowAtTheSetterAndAtOpen(readOnly: Bool) throws {
        let base = builtInTestLibrary
        var configuration = SQLiteConfiguration.default
        configuration.library.connections.setBusyTimeout = { connection, milliseconds in
          if milliseconds == 42_000 { return SQLiteResultCode.ioError.rawValue }
          return base.connections.setBusyTimeout(connection, milliseconds)
        }
        configuration.busyTimeout = .limit(.seconds(42))
        let openingError = #expect(throws: SQLiteError.self) {
          try SQLiteQueue(path: .memory, configuration: configuration)
        }
        #expect(openingError?.primaryCode == .ioError)

        configuration.busyTimeout = .limit(.seconds(5))
        let driver = try SQLiteQueue(path: .memory, configuration: configuration)
        if readOnly {
          try driver.readWithoutTransactionBlocking { connection in
            let error = #expect(throws: SQLiteError.self) {
              try connection.setBusyTimeout(.limit(.seconds(42)))
            }
            #expect(error?.primaryCode == .ioError)
            #expect(connection.busyTimeout == .limit(.seconds(5)))
            let current = try connection.fetchOne(busyTimeout)
            #expect(current == 5000)
          }
        } else {
          try driver.writeWithoutTransactionBlocking { connection in
            let error = #expect(throws: SQLiteError.self) {
              try connection.setBusyTimeout(.limit(.seconds(42)))
            }
            #expect(error?.primaryCode == .ioError)
            #expect(connection.busyTimeout == .limit(.seconds(5)))
            let current = try connection.fetchOne(busyTimeout)
            #expect(current == 5000)
          }
        }
      }

      // MARK: - Foreign keys

      @Test(arguments: SQLiteTestDriver.allCases)
      func foreignKeysTurnedOffAreRestoredWhenTheAccessEnds(_ kind: SQLiteTestDriver) async throws {
        try await kind.withDatabase(schema: listsSchema) { driver in
          let during = try await driver.writeWithoutTransaction { connection in
            let wasEnabled = connection.isForeignKeysEnabled
            try connection.setForeignKeysEnabled(false)
            #expect(wasEnabled && !connection.isForeignKeysEnabled)
            // With enforcement off the orphan is accepted, which the pragma alone would not show.
            try connection.transaction { transaction in try transaction.execute(orphan) }
            return try connection.fetchOne(foreignKeys)
          }
          #expect(during == 0)

          let (isEnabled, after) = try await driver.writeWithoutTransaction { connection in
            (connection.isForeignKeysEnabled, try connection.fetchOne(foreignKeys))
          }
          #expect(isEnabled)
          #expect(after == 1)
          await #expect(throws: SQLiteError.self) {
            try await driver.write { try $0.execute(secondOrphan) }
          }
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func foreignKeysChangesTakeEffectImmediately(
        _ kind: SQLiteTestDriver
      ) async throws {
        let probe = PragmaProbe()
        try await kind.withDatabase(
          configuration: probe.configuration(),
          readerCount: 1,
          schema: listsSchema
        ) {
          driver in
          try await driver.writeWithoutTransaction { connection in
            try connection.setForeignKeysEnabled(false)
            #expect(probe.foreignKeysChanges == ["PRAGMA foreign_keys = 0"])
            let isEnabled = connection.isForeignKeysEnabled
            #expect(!isEnabled)

            // A cursor, and so every fetch built on one.
            #expect(try connection.fetchOne(foreignKeys) == 0)
            #expect(probe.foreignKeysChanges == ["PRAGMA foreign_keys = 0"])

            // A transaction, before it begins: the pragma would be ignored once it had.
            try connection.setForeignKeysEnabled(true)
            #expect(try connection.transaction { try $0.fetchOne(foreignKeys) } == 1)

            // Both kinds of `execute`, which the orphan is refused or accepted by.
            try connection.setForeignKeysEnabled(false)
            try connection.execute("INSERT INTO entries (id, listID) VALUES (1, 1)")
            try connection.setForeignKeysEnabled(true)
            #expect(throws: SQLiteError.self) { try connection.execute(secondOrphan) }
          }

          #expect(
            probe.foreignKeysChanges == [
              "PRAGMA foreign_keys = 0",
              "PRAGMA foreign_keys = 1",
              "PRAGMA foreign_keys = 0",
              "PRAGMA foreign_keys = 1"
            ]
          )
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func unchangedSettingsDoNothingAndChangesWithoutQueriesAreRestored(_ kind: SQLiteTestDriver)
        async throws
      {
        let probe = PragmaProbe()
        try await kind.withDatabase(
          configuration: probe.configuration(),
          readerCount: 1,
          schema: listsSchema
        ) {
          driver in
          try await driver.writeWithoutTransaction { connection in
            try connection.setForeignKeysEnabled(true)
            #expect(probe.foreignKeysChanges.isEmpty)
            try connection.setForeignKeysEnabled(false)
            try connection.setForeignKeysEnabled(false)
            #expect(probe.foreignKeysChanges == ["PRAGMA foreign_keys = 0"])
          }
          #expect(
            probe.foreignKeysChanges == ["PRAGMA foreign_keys = 0", "PRAGMA foreign_keys = 1"]
          )
          #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func aFailedChangeThrowsImmediatelyAndLeavesNoPendingChange(
        _ kind: SQLiteTestDriver
      ) async throws {
        let probe = PragmaProbe(failing: "PRAGMA foreign_keys = 0")
        try await kind.withDatabase(
          configuration: probe.configuration(),
          readerCount: 1,
          schema: listsSchema
        ) {
          driver in
          probe.isFailing = true

          try await driver.writeWithoutTransaction { connection in
            let error = #expect(throws: SQLiteError.self) {
              try connection.setForeignKeysEnabled(false)
            }
            #expect(error?.sql == "PRAGMA foreign_keys = 0")
            #expect(connection.isForeignKeysEnabled == true)
            let current = try connection.fetchOne(foreignKeys)
            #expect(current == 1)
            let transactional = try connection.transaction { try $0.fetchOne(foreignKeys) }
            #expect(transactional == 1)
            #expect(
              probe.foreignKeysChanges == ["PRAGMA foreign_keys = 0", "PRAGMA foreign_keys = 1"]
            )

            probe.isFailing = false
            try connection.setForeignKeysEnabled(false)
            #expect(connection.isForeignKeysEnabled == false)
            #expect(try connection.fetchOne(foreignKeys) == 0)
          }
          #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func foreignKeysAreRestoredWhenTheBodyThrows(_ kind: SQLiteTestDriver) async throws {
        try await kind.withDatabase(schema: listsSchema) { driver throws in
          await #expect(throws: TestError()) {
            try await driver.writeWithoutTransaction { connection in
              try connection.setForeignKeysEnabled(false)
              _ = try connection.fetchOne(foreignKeys)
              throw TestError()
            }
          }

          #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func foreignKeysAreRestoredAfterATransactionLeftOpenIsRolledBack(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: listsSchema) { driver in
          let savepoint = #sql("SAVEPOINT leftover", as: Void.self)

          try await driver.writeWithoutTransaction { connection in
            try connection.setForeignKeysEnabled(false)
            // Reusing a statement the cache prepared inside the transaction leaves one open when the
            // access ends. SQLite ignores the restoring pragma until it has been rolled back.
            try connection.transaction { transaction in
              var cursor = try transaction.rowCursor(savepoint, cached: true)
              while try cursor.next() != nil {}
            }
            var cursor = try connection.rowCursor(savepoint, cached: true)
            while try cursor.next() != nil {}
          }

          #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func foreignKeysConfiguredOffAreRestoredToOff(_ kind: SQLiteTestDriver) async throws {
        var configuration = SQLiteConfiguration.default
        configuration.isForeignKeysEnabled = false
        try await kind.withDatabase(configuration: configuration) { driver in
          let (wasEnabled, during) = try await driver.writeWithoutTransaction { connection in
            let wasEnabled = connection.isForeignKeysEnabled
            try connection.setForeignKeysEnabled(true)
            return (wasEnabled, try connection.fetchOne(foreignKeys))
          }

          #expect(!wasEnabled)
          #expect(during == 1)
          #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 0)
        }
      }

      @Test
      func changingForeignKeysInsideATransactionThrowsWithoutEndingIt() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.writeWithoutTransactionBlocking { connection in
          try connection.transaction { transaction in
            for value in [false, true] {
              let error = #expect(throws: SQLiteError.self) {
                try connection.setForeignKeysEnabled(value)
              }
              #expect(error?.primaryCode == .misuse)
            }
            let current = try transaction.fetchOne(foreignKeys)
            #expect(current == 1)
            #expect(connection.isForeignKeysEnabled == true)
            try transaction.execute("CREATE TABLE kept (id INTEGER)")
          }
          try connection.execute("INSERT INTO kept VALUES (1)")
        }
      }

      // MARK: - Failed restores

      @Test
      func aFailedSetterAndFailedCleanupHoldBackTheNextAccess() async throws {
        let probe = PragmaProbe(failing: "PRAGMA foreign_keys = ")
        let driver = try SQLiteQueue(path: .memory, configuration: probe.configuration())
        probe.isFailing = true
        let error = await #expect(throws: SQLiteError.self) {
          try await driver.writeWithoutTransaction { connection in
            try connection.setForeignKeysEnabled(false)
          }
        }
        #expect(error?.sql == "PRAGMA foreign_keys = 0")
        // Even though the last successful setting equals the configured value, cleanup must retry.
        let held = await #expect(throws: SQLiteError.self) {
          try await driver.writeWithoutTransaction { _ in Issue.record("Cleanup is still failing") }
        }
        #expect(held?.sql == "PRAGMA foreign_keys = 1")
        probe.isFailing = false
        let current = try await driver.write { try $0.fetchOne(foreignKeys) }
        #expect(current == 1)
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func aFailedRestoreFailsTheAccessAndIsRetriedByTheNextOne(
        _ kind: SQLiteTestDriver
      ) async throws {
        let probe = PragmaProbe(failing: "PRAGMA foreign_keys = 1")
        try await kind.withDatabase(
          configuration: probe.configuration(),
          readerCount: 1,
          schema: listsSchema
        ) {
          driver in
          probe.isFailing = true

          // The body succeeded, so the restore's failure is what the access reports.
          let error = await #expect(throws: SQLiteError.self) {
            try await driver.writeWithoutTransaction { connection in
              try connection.setForeignKeysEnabled(false)
              _ = try connection.fetchOne(foreignKeys)
            }
          }
          #expect(error?.primaryCode == .ioError)
          #expect(error?.sql == "PRAGMA foreign_keys = 1")

          // Every later access restores first, and fails without running its body while it cannot.
          let ran = Lock(false)
          let retried = await #expect(throws: SQLiteError.self) {
            try await driver.write { _ in ran.withLock { $0 = true } }
          }
          #expect(retried?.sql == "PRAGMA foreign_keys = 1")
          await #expect(throws: SQLiteError.self) {
            try await driver.writeWithoutTransaction { _ in ran.withLock { $0 = true } }
          }
          if kind == .queue {
            // A queue reads on the same connection, so its reads are held back too.
            await #expect(throws: SQLiteError.self) {
              try await driver.read { _ in ran.withLock { $0 = true } }
            }
          }
          #expect(!ran.withLock { $0 })

          probe.isFailing = false
          let (isEnabled, restored) = try await driver.writeWithoutTransaction { connection in
            (connection.isForeignKeysEnabled, try connection.fetchOne(foreignKeys))
          }
          #expect(isEnabled)
          #expect(restored == 1)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func aFailedRestoreDoesNotMaskTheBodysError(_ kind: SQLiteTestDriver) async throws {
        let probe = PragmaProbe(failing: "PRAGMA foreign_keys = 1")
        try await kind.withDatabase(
          configuration: probe.configuration(),
          readerCount: 1,
          schema: listsSchema
        ) {
          driver throws in
          probe.isFailing = true

          await #expect(throws: TestError()) {
            try await driver.writeWithoutTransaction { connection in
              try connection.setForeignKeysEnabled(false)
              _ = try connection.fetchOne(foreignKeys)
              throw TestError()
            }
          }

          // The setting stayed marked as changed, so the next access restores it before it begins.
          let held = await #expect(throws: SQLiteError.self) {
            try await driver.write { try $0.fetchOne(foreignKeys) }
          }
          #expect(held?.sql == "PRAGMA foreign_keys = 1")
          probe.isFailing = false
          #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
        }
      }

      @Test
      func aFailedQueryOnlyRestoreHoldsBackTheNextWrite() async throws {
        let probe = PragmaProbe(failing: "PRAGMA query_only = 0")
        let driver = try SQLiteQueue(path: .memory, configuration: probe.configuration())
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        probe.isFailing = true

        let error = await #expect(throws: SQLiteError.self) {
          try await driver.read { transaction in
            try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
          }
        }
        #expect(error?.sql == "PRAGMA query_only = 0")

        // Left read-only, the connection refuses to write until it has been made writable again.
        let held = await #expect(throws: SQLiteError.self) {
          try await driver.write { transaction in
            try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          }
        }
        #expect(held?.sql == "PRAGMA query_only = 0")

        probe.isFailing = false
        try await driver.write { transaction in
          try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
        }
        let count = try await driver.read { transaction in
          try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
        }
        #expect(count == 1)
      }
    }

    /// Records foreign-key changes and injects execution failures for a pragma prefix while enabled.
    private final class PragmaProbe: Sendable {
      private let failingSQL: String?
      private let failing = Lock(false)
      private let changes = Lock([String]())

      init(failing sql: String? = nil) {
        self.failingSQL = sql
      }

      var isFailing: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
      }

      /// Every `PRAGMA foreign_keys = …` statement stepped since the connection was configured,
      /// failed or not.
      var foreignKeysChanges: [String] { changes.withLock { $0 } }

      func configuration() -> SQLiteConfiguration {
        let base = builtInTestLibrary
        var configuration = SQLiteConfiguration.default
        configuration.library = base
        configuration.library.statements.execution.step = { [self] statement in
          guard let text = base.statements.inspection.sql(statement) else {
            return base.statements.execution.step(statement)
          }
          let sql = String(cString: text)
          // Configuring the connection spells the pragma `ON` or `OFF`, which this leaves out.
          if sql.hasPrefix("PRAGMA foreign_keys = "), sql.last?.isNumber == true {
            changes.withLock { $0.append(sql) }
          }
          if isFailing, let failingSQL, sql.hasPrefix(failingSQL) {
            return SQLiteResultCode.ioError.rawValue
          }
          return base.statements.execution.step(statement)
        }
        return configuration
      }
    }

    private let listsSchema = """
      CREATE TABLE lists (id INTEGER PRIMARY KEY);
      CREATE TABLE entries (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists (id));
      """
    private let busyTimeout = #sql("PRAGMA busy_timeout", as: Int.self)
    private let foreignKeys = #sql("PRAGMA foreign_keys", as: Int.self)
    private let orphan = #sql("INSERT INTO entries (id, listID) VALUES (1, 1)", as: Void.self)
    private let secondOrphan = #sql("INSERT INTO entries (id, listID) VALUES (2, 2)", as: Void.self)
  #endif
#endif
