#if BuiltInSQLite
  import Foundation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct OrbitDatabaseMigratorTests {
    // MARK: - Order

    @Test(arguments: SQLiteTestDriver.allCases)
    func migrationsRunOnceInRegistrationOrder(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      let migrator = loggingMigrator(["one", "two", "three"])

      try await migrator.migrate(driver)
      try await migrator.migrate(driver)

      #expect(try await log(in: driver) == ["one", "two", "three"])
      #expect(
        try await driver.read { try migrator.appliedMigrations($0) } == ["one", "two", "three"]
      )
    }

    @Test
    func migrationsListsTheRegisteredIdentifiersInRegistrationOrder() {
      var migrator = OrbitDatabaseMigrator()
      #expect(migrator.migrations.isEmpty)
      for identifier in ["b", "c", "a"] {
        migrator.registerMigration(identifier) { _ in }
      }
      #expect(migrator.migrations == ["b", "c", "a"])
      #expect(OrbitDatabaseMigrator.grdb.migrations.isEmpty)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func blockingMigrationRunsOnceInRegistrationOrder(_ kind: SQLiteTestDriver) throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      let migrator = loggingMigrator(["one", "two"])

      try migrator.migrateBlocking(driver)
      try migrator.migrateBlocking(driver)

      let log = try driver.readBlocking { transaction in
        try transaction.fetchAll(#sql("SELECT identifier FROM log ORDER BY rowid", as: String.self))
      }
      #expect(log == ["one", "two"])
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func migratingAnUpToDateDatabaseWritesAndAnnouncesNothing(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      try await checkUpToDateMigrationIsSilent(on: try kind.open(in: directory))
    }

    private func checkUpToDateMigrationIsSilent(
      on writer: some OrbitObservableDatabase,
      eraseDatabaseOnSchemaChange: Bool = false
    ) async throws {
      let network = InMemoryIPCTransport.Network()
      let identifier = OrbitDatabaseIdentifier(rawValue: "migrator-\(UUID().uuidString)")
      let database = OrbitDatabase(
        writer: writer,
        id: identifier,
        transport: InMemoryIPCTransport(network: network)
      )
      let peerTransport = InMemoryIPCTransport(network: network)
      let announcements = Lock(0)
      let peerSubscription = try peerTransport.subscribe(to: identifier) { _ in
        announcements.withLock { $0 += 1 }
      }
      let observer = MigrationEventObserver()
      let observerSubscription = try database.subscribe(transactionObserver: observer)
      let migrator = loggingMigrator(
        ["one", "two"],
        eraseDatabaseOnSchemaChange: eraseDatabaseOnSchemaChange
      )

      try await migrator.migrate(database)
      #expect(announcements.withLock { $0 } == 1)
      #expect(observer.commitCount == 2)
      // Only what a write reports is counted: finding out that nothing is pending reads.
      let eventsAfterFirstRun = observer.eventCount

      try await migrator.migrate(database)
      try migrator.migrateBlocking(database)

      #expect(announcements.withLock { $0 } == 1)
      #expect(observer.eventCount == eventsAfterFirstRun)
      _ = (peerSubscription, observerSubscription)
    }

    // Exit tests run the test in a child process, which only these platforms can spawn.
    #if os(macOS) || os(Linux) || os(Windows)
      @Test
      func registeringAnIdentifierTwiceStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
          var migrator = OrbitDatabaseMigrator()
          migrator.registerMigration("one") { _ in }
          migrator.registerMigration("one") { _ in }
        }
      }
    #endif

    // MARK: - Targets

    @Test(arguments: SQLiteTestDriver.allCases)
    func migratingUpToATargetStopsAfterIt(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      let migrator = loggingMigrator(["one", "two", "three"])

      try await migrator.migrate(driver, upTo: "two")
      #expect(try await log(in: driver) == ["one", "two"])

      try await migrator.migrate(driver, upTo: "two")
      #expect(try await log(in: driver) == ["one", "two"])

      try await migrator.migrate(driver)
      #expect(try await log(in: driver) == ["one", "two", "three"])
    }

    @Test
    func unregisteredTargetThrowsBeforeWritingAnything() async throws {
      let driver = try SQLiteQueue(path: .memory)
      let migrator = loggingMigrator(["one"])

      let error = await #expect(throws: OrbitDatabaseMigrationTargetError.self) {
        try await migrator.migrate(driver, upTo: "missing")
      }

      #expect(error == OrbitDatabaseMigrationTargetError(target: "missing", reason: .unregistered))
      #expect(error?.description.contains("\"missing\"") == true)
      #expect(try await driver.read { try migrator.appliedIdentifiers($0) }.isEmpty)
    }

    @Test
    func targetBeforeAnAppliedMigrationThrows() async throws {
      let driver = try SQLiteQueue(path: .memory)
      let migrator = loggingMigrator(["one", "two", "three"])
      try await migrator.migrate(driver, upTo: "two")

      let error = await #expect(throws: OrbitDatabaseMigrationTargetError.self) {
        try await migrator.migrate(driver, upTo: "one")
      }

      #expect(
        error == OrbitDatabaseMigrationTargetError(target: "one", reason: .migratedBeyond("two"))
      )
      #expect(try await log(in: driver) == ["one", "two"])
    }

    // MARK: - Foreign keys

    @Test(arguments: SQLiteTestDriver.allCases)
    func deferredChecksLetATableRebuildKeepItsCascadingChildren(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var migrator = makeMigrator()
      migrator.registerMigration("Create lists", migrate: createListsAndReminders)
      migrator.registerMigration("Add list colors") { transaction in
        // SQLite's procedure for a change `ALTER TABLE` cannot make: build the new table, copy
        // the rows across, drop the old one, and give the new one its name.
        try transaction.execute(
          """
          CREATE TABLE new_lists (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            color TEXT NOT NULL DEFAULT 'blue'
          );
          INSERT INTO new_lists (id, title) SELECT id, title FROM lists;
          DROP TABLE lists;
          ALTER TABLE new_lists RENAME TO lists;
          """
        )
      }

      try await migrator.migrate(driver)

      let (reminders, colors) = try await driver.read { transaction in
        (
          try transaction.fetchOne(#sql("SELECT count(*) FROM reminders", as: Int.self)),
          try transaction.fetchAll(#sql("SELECT color FROM lists", as: String.self))
        )
      }
      #expect(reminders == 2)
      #expect(colors == ["blue"])
      try await expectWriterForeignKeys(true, on: driver)
    }

    // Turso cannot find violations; `deferredMigrationsThatWouldBeCheckedFailBeforeRunningOnTurso`
    // covers what it does instead.
    #if !Turso
      @Test(arguments: SQLiteTestDriver.allCases)
      func violationRollsBackOnlyItsMigration(_ kind: SQLiteTestDriver) async throws {
        let directory = try makeShortTemporaryDirectory("migrate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = try kind.open(in: directory)
        let ranLast = Lock(false)
        var migrator = OrbitDatabaseMigrator()
        migrator.registerMigration("Create lists", migrate: createListsAndReminders)
        migrator.registerMigration("Orphan a reminder") { transaction in
          try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
        }
        migrator.registerMigration("Never reached") { _ in ranLast.withLock { $0 = true } }

        let error = await #expect(throws: OrbitDatabaseForeignKeyViolationError.self) {
          try await migrator.migrate(driver)
        }

        #expect(error?.migration == "Orphan a reminder")
        #expect(
          error?.violations == [
            .init(table: "reminders", rowID: 3, parentTable: "lists", foreignKeyIndex: 0)
          ]
        )
        #expect(!ranLast.withLock { $0 })
        #expect(
          try await driver.read { try migrator.appliedMigrations($0) } == ["Create lists"]
        )
        let reminders = try await driver.read { transaction in
          try transaction.fetchOne(#sql("SELECT count(*) FROM reminders", as: Int.self))
        }
        #expect(reminders == 2)
        try await expectWriterForeignKeys(true, on: driver)
      }
    #endif

    @Test(arguments: SQLiteTestDriver.allCases)
    func immediateChecksKeepForeignKeysOnDuringTheMigration(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      let foreignKeys = Lock([Int]())
      var migrator = makeMigrator()
      migrator.registerMigration("Create lists") { transaction in
        try createListsAndReminders(transaction)
        try foreignKeys.withLock { $0.append(try foreignKeysPragma(in: transaction)) }
      }
      migrator.registerMigration("Orphan a reminder", foreignKeyChecks: .immediate) {
        transaction in
        try foreignKeys.withLock { $0.append(try foreignKeysPragma(in: transaction)) }
        try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
      }

      let error = await #expect(throws: SQLiteError.self) {
        try await migrator.migrate(driver)
      }

      #expect(error?.primaryCode == .constraint)
      #expect(foreignKeys.withLock { $0 } == [0, 1])
      #expect(
        try await driver.read { try migrator.appliedMigrations($0) } == ["Create lists"]
      )
    }

    @Test
    func turningDeferredChecksOffSkipsTheCheckOfLaterMigrationsOnly() async throws {
      let foreignKeys = Lock([Int]())
      var migrator = OrbitDatabaseMigrator()
      // Immediate, so that only the orphans' migrations tell checked from unchecked, and so that it
      // runs on Turso, which cannot check.
      migrator.registerMigration(
        "Create lists",
        foreignKeyChecks: .immediate,
        migrate: createListsAndReminders
      )
      var checked = migrator
      checked.registerMigration("Checked orphan") { transaction in
        try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
      }
      #expect(migrator.defersForeignKeyChecks)
      migrator.defersForeignKeyChecks = false
      migrator.registerMigration("Unchecked orphan") { transaction in
        try foreignKeys.withLock { $0.append(try foreignKeysPragma(in: transaction)) }
        try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
      }

      // Still run with foreign keys off, but not checked.
      let uncheckedDriver = try SQLiteQueue(path: .memory)
      try await migrator.migrate(uncheckedDriver)
      #expect(foreignKeys.withLock { $0 } == [0])
      try await expectWriterForeignKeys(true, on: uncheckedDriver)
      #if !Turso
        let orphans = try await uncheckedDriver.read { try $0.foreignKeyViolations() }
        #expect(orphans.map(\.table) == ["reminders"])
      #endif

      // The property is read when a migration is registered, so one registered before it was
      // turned off keeps its check, which Turso refuses to run rather than skip.
      checked.defersForeignKeyChecks = false
      let checkedDriver = try SQLiteQueue(path: .memory)
      #if Turso
        await #expect(throws: SQLiteFeatureUnavailableError.self) {
          try await checked.migrate(checkedDriver)
        }
      #else
        await #expect(throws: OrbitDatabaseForeignKeyViolationError.self) {
          try await checked.migrate(checkedDriver)
        }
      #endif
    }

    @Test
    func disablingDeferredChecksReturnsACopyAndLeavesTheOriginal() async throws {
      var original = OrbitDatabaseMigrator()
      // Immediate, so that only the orphan's migration tells the two apart, and so that it runs on
      // Turso, which cannot check.
      original.registerMigration(
        "Create lists",
        foreignKeyChecks: .immediate,
        migrate: createListsAndReminders
      )

      var disabled = original.disablingDeferredForeignKeyChecks()
      #expect(!disabled.defersForeignKeyChecks)
      #expect(original.defersForeignKeyChecks)
      #expect(disabled.migrations == original.migrations)

      let orphan: @Sendable (borrowing SQLiteWriteTransaction) throws -> Void = { transaction in
        try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
      }
      disabled.registerMigration("Orphan a reminder", migrate: orphan)
      original.registerMigration("Orphan a reminder", migrate: orphan)

      let disabledDriver = try SQLiteQueue(path: .memory)
      try await disabled.migrate(disabledDriver)
      let originalDriver = try SQLiteQueue(path: .memory)
      #if Turso
        await #expect(throws: SQLiteFeatureUnavailableError.self) {
          try await original.migrate(originalDriver)
        }
      #else
        await #expect(throws: OrbitDatabaseForeignKeyViolationError.self) {
          try await original.migrate(originalDriver)
        }
      #endif
    }

    @Test
    func foreignKeysOffOnTheConnectionAreNeitherToggledNorChecked() async throws {
      var configuration = SQLiteConfiguration.default
      configuration.isForeignKeysEnabled = false
      let driver = try SQLiteQueue(path: .memory, configuration: configuration)
      let foreignKeys = Lock([Int]())
      var migrator = OrbitDatabaseMigrator()
      migrator.registerMigration("Create lists", migrate: createListsAndReminders)
      migrator.registerMigration("Orphan a reminder") { transaction in
        try foreignKeys.withLock { $0.append(try foreignKeysPragma(in: transaction)) }
        try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
      }

      try await migrator.migrate(driver)

      #expect(foreignKeys.withLock { $0 } == [0])
      try await expectWriterForeignKeys(false, on: driver)
      #expect(try await driver.read { try migrator.hasCompletedMigrations($0) })
    }

    #if Turso
      @Test
      func deferredMigrationsThatWouldBeCheckedFailBeforeRunningOnTurso() async throws {
        let driver = try SQLiteQueue(path: .memory)
        let ranChecked = Lock(false)
        var migrator = OrbitDatabaseMigrator()
        migrator.registerMigration(
          "Create lists",
          foreignKeyChecks: .immediate,
          migrate: createListsAndReminders
        )
        migrator.registerMigration("Checked") { transaction in
          ranChecked.withLock { $0 = true }
          try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
        }

        let error = await #expect(throws: SQLiteFeatureUnavailableError.self) {
          try await migrator.migrate(driver)
        }

        #expect(
          error == SQLiteFeatureUnavailableError(libraryName: "Turso", feature: .foreignKeyCheck)
        )
        #expect(!ranChecked.withLock { $0 })
        #expect(
          try await driver.read { try migrator.appliedMigrations($0) } == ["Create lists"]
        )
        let reminders = try await driver.read { transaction in
          try transaction.fetchOne(#sql("SELECT count(*) FROM reminders", as: Int.self))
        }
        #expect(reminders == 2)
        try await expectWriterForeignKeys(true, on: driver)

        // The temporary database `hasSchemaChanges` migrates refuses such a migration the same way.
        var checkedHistory = OrbitDatabaseMigrator()
        checkedHistory.registerMigration("Create lists", migrate: createListsAndReminders)
        await #expect(throws: SQLiteFeatureUnavailableError.self) {
          try await driver.read { try checkedHistory.hasSchemaChanges($0) }
        }
      }

      @Test
      func immediateAndUncheckedMigrationsApplyOnTurso() async throws {
        let driver = try SQLiteQueue(path: .memory)
        var migrator = OrbitDatabaseMigrator()
        migrator.registerMigration(
          "Create lists",
          foreignKeyChecks: .immediate,
          migrate: createListsAndReminders
        )
        migrator.defersForeignKeyChecks = false
        migrator.registerMigration("Unchecked") { transaction in
          try transaction.execute("INSERT INTO lists VALUES (2, 'Chores')")
        }
        var disabled = migrator.disablingDeferredForeignKeyChecks()
        disabled.registerMigration("Disabled") { transaction in
          try transaction.execute("INSERT INTO lists VALUES (3, 'Work')")
        }

        try await disabled.migrate(driver)

        #expect(
          try await driver.read { try disabled.appliedMigrations($0) }
            == ["Create lists", "Unchecked", "Disabled"]
        )
        // Turso still enforces foreign keys statement by statement in an immediate migration.
        var orphaning = disabled
        orphaning.registerMigration("Orphan", foreignKeyChecks: .immediate) { transaction in
          try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
        }
        await #expect(throws: SQLiteError.self) { try await orphaning.migrate(driver) }
        #expect(try await driver.read { try orphaning.hasCompletedMigrations($0) } == false)
      }
    #else
      @Test
      func everyBuildButTursoCanCheckForeignKeys() {
        let base = builtInTestLibrary
        let custom = SQLiteLibrary(
          runtime: base.runtime,
          connections: base.connections,
          statements: base.statements,
          bindings: base.bindings,
          columns: base.columns
        )
        #expect(base.isForeignKeyCheckAvailable)
        #expect(custom.isForeignKeyCheckAvailable)
      }
    #endif

    // Turso refuses the check; `TursoCompatibilityTests` covers that.
    #if !Turso
      @Test(arguments: SQLiteTestDriver.allCases)
      func foreignKeyViolationsAreReadOutsideTheMigrator(_ kind: SQLiteTestDriver) async throws {
        let directory = try makeShortTemporaryDirectory("migrate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = try kind.open(in: directory)
        let orphan = OrbitDatabaseForeignKeyViolation(
          table: "reminders",
          rowID: 3,
          parentTable: "lists",
          foreignKeyIndex: 0
        )

        let (before, during) = try await driver.writeWithoutTransaction { connection in
          try connection.transaction { try createListsAndReminders($0) }
          let before = try connection.foreignKeyViolations()
          // A table rebuild outside the migrator: foreign keys off, the change, then the check.
          connection.isForeignKeysEnabled = false
          let during = try connection.transaction { transaction in
            try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
            return try transaction.foreignKeyViolations()
          }
          return (before, during)
        }

        #expect(before.isEmpty)
        #expect(during == [orphan])
        // Foreign keys are back on for these, and the check finds the orphan all the same.
        try await expectWriterForeignKeys(true, on: driver)
        #expect(try await driver.read { try $0.foreignKeyViolations() } == [orphan])
        #expect(
          try await driver.readWithoutTransaction { try $0.foreignKeyViolations() } == [orphan]
        )
      }
    #endif

    // MARK: - The table of applied migrations

    @Test(arguments: SQLiteTestDriver.allCases)
    func customTableNameIsQuotedAndUsedInsteadOfTheDefault(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var migrator = makeMigrator(OrbitDatabaseMigrator(tableName: #"app "migrations""#))
      migrator.registerMigration("one") { _ in }

      try await migrator.migrate(driver)

      let tables = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name", as: String.self)
        )
      }
      #expect(tables == [#"app "migrations""#])
      #expect(try await driver.read { try migrator.appliedIdentifiers($0) } == ["one"])
    }

    @Test
    func grdbTableNameAdoptsAnExistingGRDBHistory() async throws {
      let driver = try SQLiteQueue(path: .memory)
      // What GRDB's `DatabaseMigrator` leaves behind after applying its first migration.
      try await driver.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
          INSERT INTO grdb_migrations VALUES ('v1');
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          """
        )
      }
      var migrator = makeMigrator(.grdb)
      migrator.registerMigration("v1") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      migrator.registerMigration("v2") { transaction in
        try transaction.execute("ALTER TABLE items ADD COLUMN title TEXT")
      }

      try await migrator.migrate(driver)

      #expect(try await driver.read { try migrator.appliedMigrations($0) } == ["v1", "v2"])
      let columns = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
        )
      }
      #expect(columns == ["id", "title"])
    }

    @Test
    func grdbMigratorRecordsItsHistoryInGRDBsTable() async throws {
      let driver = try SQLiteQueue(path: .memory)
      var migrator = makeMigrator(.grdb)
      migrator.registerMigration("v1") { _ in }

      try await migrator.migrate(driver)

      let tables = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM sqlite_schema WHERE type = 'table'", as: String.self)
        )
      }
      #expect(tables == ["grdb_migrations"])
      let recorded = try await driver.read { transaction in
        try transaction.fetchAll(#sql("SELECT identifier FROM grdb_migrations", as: String.self))
      }
      #expect(recorded == ["v1"])
    }

    // MARK: - Migrating on a connection

    @Test(arguments: SQLiteTestDriver.allCases)
    func migratingOnAConnectionAppliesPendingMigrationsOnce(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      let migrator = loggingMigrator(["one", "two", "three"])

      let appliedUpToTarget = try await driver.writeWithoutTransaction { connection in
        try migrator.migrate(connection, upTo: "two")
        let applied = try migrator.appliedMigrations(connection)
        try migrator.migrate(connection)
        try migrator.migrate(connection)
        return applied
      }

      #expect(appliedUpToTarget == ["one", "two"])
      #expect(try await log(in: driver) == ["one", "two", "three"])
    }

    @Test
    func migratingOnAConnectionPutsBackTheForeignKeysTheCallerSet() async throws {
      var configuration = SQLiteConfiguration.default
      configuration.isForeignKeysEnabled = false
      let driver = try SQLiteQueue(path: .memory, configuration: configuration)
      let foreignKeys = Lock([Int]())
      var migrator = makeMigrator()
      migrator.registerMigration("Create lists") { transaction in
        try createListsAndReminders(transaction)
        try foreignKeys.withLock { $0.append(try foreignKeysPragma(in: transaction)) }
      }

      let (isEnabled, pragma) = try await driver.writeWithoutTransaction { connection in
        connection.isForeignKeysEnabled = true
        try migrator.migrate(connection)
        return (
          connection.isForeignKeysEnabled,
          try connection.fetchOne(#sql("PRAGMA foreign_keys", as: Int.self))
        )
      }

      // Off while the migration ran, then back to what the caller set rather than the
      // configured value, which the end of the access restores instead.
      #expect(foreignKeys.withLock { $0 } == [0])
      #expect(isEnabled)
      #expect(pragma == 1)
      try await expectWriterForeignKeys(false, on: driver)
    }

    // MARK: - Restoring the connection

    @Test(arguments: SQLiteTestDriver.allCases)
    func failingMigrationRethrowsItsErrorAndRestoresTheConnection(
      _ kind: SQLiteTestDriver
    ) async throws {
      struct MigrationFailure: Error, Equatable {}

      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var migrator = makeMigrator()
      migrator.registerMigration("one") { _ in }
      migrator.registerMigration("two") { transaction in
        try transaction.execute("CREATE TABLE doomed (id INTEGER)")
        throw MigrationFailure()
      }

      let error = await #expect(throws: MigrationFailure.self) {
        try await driver.writeWithoutTransaction { connection in
          connection.busyTimeout = .limit(.seconds(42))
          try migrator.migrate(connection)
        }
      }

      #expect(error == MigrationFailure())
      try await expectWriterForeignKeys(true, on: driver)
      #expect(try await writerPragma("busy_timeout", on: driver) == 5000)
      #expect(try await driver.read { try migrator.appliedMigrations($0) } == ["one"])
    }

    @Test(arguments: [true, false])
    func failedMigrationPutsBackTheCallersForeignKeys(_ callerValue: Bool) async throws {
      struct MigrationFailure: Error {}

      let driver = try SQLiteQueue(path: .memory)
      let during = Lock<Int?>(nil)
      var migrator = makeMigrator()
      migrator.registerMigration("one") { transaction in
        let value = try foreignKeysPragma(in: transaction)
        during.withLock { $0 = value }
        throw MigrationFailure()
      }

      let (isEnabled, pragma) = try await driver.writeWithoutTransaction { connection in
        connection.isForeignKeysEnabled = callerValue
        #expect(throws: MigrationFailure.self) { try migrator.migrate(connection) }
        return (
          connection.isForeignKeysEnabled,
          try connection.fetchOne(#sql("PRAGMA foreign_keys", as: Int.self))
        )
      }

      // Off while the failed migration ran, then back to the caller's value before their next
      // statement, rather than left off until the access ends.
      #expect(during.withLock { $0 } == 0)
      #expect(isEnabled == callerValue)
      #expect(pragma == (callerValue ? 1 : 0))
      try await expectWriterForeignKeys(true, on: driver)
    }

    @Test
    func cancellingStopsOnAMigrationBoundaryAndRestoresTheConnection() async throws {
      let steps = Lock(0)
      let base = builtInTestLibrary
      var configuration = SQLiteConfiguration.default
      configuration.library = base
      configuration.library.statements.execution.step = { statement in
        if let sql = base.statements.inspection.sql(statement),
          String(cString: sql).contains("RECURSIVE counter")
        {
          steps.withLock { $0 += 1 }
        }
        return base.statements.execution.step(statement)
      }
      let driver = try SQLiteQueue(path: .memory, configuration: configuration)
      var migrator = makeMigrator()
      migrator.registerMigration("one") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      migrator.registerMigration("endless") { transaction in
        try transaction.execute("INSERT INTO items (id) VALUES (1)")
        _ = try transaction.fetchAll(
          #sql(
            """
            WITH RECURSIVE counter(x) AS (
              SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 2000000000
            )
            SELECT count(*) FROM counter
            """,
            as: Int.self
          )
        )
      }

      let running = Task { [migrator] in
        try await driver.writeWithoutTransaction { connection in
          connection.busyTimeout = .maximum
          try migrator.migrate(connection)
        }
      }
      try await waitUntil { steps.withLock { $0 } > 0 }
      running.cancel()

      await #expect(throws: CancellationError.self) {
        try await running.value
      }
      #expect(try await driver.read { try migrator.appliedMigrations($0) } == ["one"])
      let items = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
      }
      #expect(items == 0)
      try await expectWriterForeignKeys(true, on: driver)
      #expect(try await writerPragma("busy_timeout", on: driver) == 5000)
    }

    // MARK: - Busy databases

    @Test
    func busyMigrationFailsWithoutRetryingAndRestoresTheConnection() async throws {
      let begins = Lock(0)
      let isBusy = Lock(false)
      let base = builtInTestLibrary
      var configuration = SQLiteConfiguration.default
      configuration.library = base
      configuration.library.statements.execution.step = { statement in
        if isBusy.withLock({ $0 }), let sql = base.statements.inspection.sql(statement),
          String(cString: sql).hasPrefix("BEGIN IMMEDIATE")
        {
          begins.withLock { $0 += 1 }
          return SQLiteResultCode.busy.rawValue
        }
        return base.statements.execution.step(statement)
      }
      let driver = try SQLiteQueue(path: .memory, configuration: configuration)
      try await loggingMigrator(["one"]).migrate(driver)
      let migrator = loggingMigrator(["one", "two"])

      isBusy.withLock { $0 = true }
      let error = await #expect(throws: SQLiteError.self) {
        try await migrator.migrate(driver)
      }
      isBusy.withLock { $0 = false }

      #expect(error?.primaryCode == .busy)
      #expect(begins.withLock { $0 } == 1)
      #expect(try await log(in: driver) == ["one"])
      // The migration had turned foreign keys off before it found the database busy.
      try await expectWriterForeignKeys(true, on: driver)
      #expect(try await writerPragma("busy_timeout", on: driver) == 5000)
    }

    @Test
    func raisedBusyTimeoutWaitsOutALockHeldLongerThanTheConfiguredOne() async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))
      let holder = try SQLiteQueue(path: path)
      var configuration = SQLiteConfiguration.default
      configuration.busyTimeout = .limit(.milliseconds(100))
      let driver = try SQLiteQueue(path: path, configuration: configuration)
      let migrator = loggingMigrator(["one"])

      let isHeld = Lock(false)
      let holding = Task {
        try await holder.write { transaction in
          try transaction.execute("CREATE TABLE held (id INTEGER)")
          isHeld.withLock { $0 = true }
          Thread.sleep(forTimeInterval: 1)
        }
      }
      try await waitUntil { isHeld.withLock { $0 } }

      // The configured timeout runs out while the lock is still held.
      let error = await #expect(throws: SQLiteError.self) {
        try await migrator.migrate(driver)
      }
      #expect(error?.primaryCode == .busy)

      let clock = ContinuousClock()
      let started = clock.now
      try await driver.writeWithoutTransaction { connection in
        connection.busyTimeout = .limit(.seconds(30))
        try migrator.migrate(connection)
      }
      try await holding.value

      #expect(clock.now - started > .milliseconds(100))
      #expect(try await log(in: driver) == ["one"])
      #expect(try await writerPragma("busy_timeout", on: driver) == 100)
    }

    @Test
    func separatePoolsMigratingTheSameFileApplyEachMigrationOnce() async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))
      let first = try SQLitePool(path: path)
      let second = try SQLitePool(path: path)
      let migrator = makeContendedMigrator()

      async let firstRun: Void = migrator.migrate(first)
      async let secondRun: Void = migrator.migrate(second)
      _ = try await (firstRun, secondRun)

      try await expectContendedMigrationsAppliedOnce(in: first)
    }

    // MARK: - Inspection

    @Test(arguments: SQLiteTestDriver.allCases)
    func inspectingAFreshDatabaseReportsNothingApplied(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      let migrator = loggingMigrator(["one", "two"])

      let fromRead = try await driver.read { try Inspection(of: migrator, in: $0) }
      let fromConnection = try await driver.readWithoutTransaction { connection in
        try Inspection(of: migrator, in: connection)
      }
      let fromWrite = try await driver.write { try Inspection(of: migrator, in: $0) }
      let fromWriteConnection = try await driver.writeWithoutTransaction { connection in
        try Inspection(of: migrator, in: connection)
      }

      let nothing = Inspection(
        identifiers: [],
        applied: [],
        completed: [],
        hasCompleted: false,
        hasBeenSuperseded: false
      )
      #expect(fromRead == nothing)
      #expect(fromConnection == nothing)
      #expect(fromWrite == nothing)
      #expect(fromWriteConnection == nothing)
      // Inspecting reads the schema to learn the table is missing, and creates nothing.
      let tables = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM sqlite_schema", as: Int.self))
      }
      #expect(tables == 0)
    }

    @Test
    func inspectionTellsAppliedCompletedAndSupersededApart() async throws {
      let driver = try SQLiteQueue(path: .memory)
      let migrator = loggingMigrator(["one", "two", "three"])
      try await migrator.migrate(driver, upTo: "one")
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO orbit_migrations VALUES ('three')")
      }

      #expect(
        try await driver.read { try Inspection(of: migrator, in: $0) }
          == Inspection(
            identifiers: ["one", "three"],
            applied: ["one", "three"],
            completed: ["one"],
            hasCompleted: false,
            hasBeenSuperseded: false
          )
      )

      try await driver.write { transaction in
        try transaction.execute("INSERT INTO orbit_migrations VALUES ('from a newer build')")
      }
      try await migrator.migrate(driver)

      #expect(
        try await driver.read { try Inspection(of: migrator, in: $0) }
          == Inspection(
            identifiers: ["one", "two", "three", "from a newer build"],
            applied: ["one", "two", "three"],
            completed: ["one", "two", "three"],
            hasCompleted: true,
            hasBeenSuperseded: true
          )
      )
      // The migration recorded by hand never ran, and the one registered before it did.
      #expect(try await log(in: driver) == ["one", "two"])
    }

    // MARK: - Observation

    @Test
    func peerObservationRefetchesAfterAMigration() async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))
      let network = InMemoryIPCTransport.Network()
      let identifier = OrbitDatabaseIdentifier(rawValue: "migrator-peer-\(UUID().uuidString)")
      let migratingDatabase = OrbitDatabase(
        writer: try SQLiteQueue(path: path),
        id: identifier,
        transport: InMemoryIPCTransport(network: network)
      )
      let observingDatabase = OrbitDatabase(
        writer: try SQLiteQueue(path: path),
        id: identifier,
        transport: InMemoryIPCTransport(network: network)
      )
      let migrator = loggingMigrator(["one", "two"])
      let values = Lock([[String]]())
      let subscription =
        try OrbitValueObservation
        .tracking { try migrator.appliedMigrations($0) }
        .subscribe(
          to: observingDatabase,
          onError: { _ in },
          onChange: { change in values.withLock { $0.append(change.value) } }
        )
      try await waitUntil { !values.withLock { $0 }.isEmpty }

      try await migrator.migrate(migratingDatabase)

      try await waitUntil { values.withLock { $0 }.last == ["one", "two"] }
      #expect(values.withLock { $0 }.first == [])
      _ = subscription
    }

    // MARK: - Schema changes

    // MARK: hasSchemaChanges

    @Test(arguments: SQLiteTestDriver.allCases)
    func hasSchemaChangesIsFalseOnAFreshDatabaseAndOnAnUpToDateOne(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("schema")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      let migrator = loggingMigrator(["one", "two"])

      // Nothing has been applied yet, so there is nothing to compare.
      #expect(try await driver.read { try migrator.hasSchemaChanges($0) } == false)

      try await migrator.migrate(driver)

      #expect(try await driver.read { try migrator.hasSchemaChanges($0) } == false)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func hasSchemaChangesIsTrueWhenAnAppliedMigrationIsRemoved(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("schema")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      try await loggingMigrator(["one", "two", "three"]).migrate(driver)

      let withoutTwo = loggingMigrator(["one", "three"])

      #expect(try await driver.read { try withoutTwo.hasSchemaChanges($0) } == true)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func hasSchemaChangesIsTrueWhenAnAppliedMigrationIsRenamed(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("schema")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      try await loggingMigrator(["one", "two"]).migrate(driver)

      let renamed = loggingMigrator(["one", "two renamed"])

      #expect(try await driver.read { try renamed.hasSchemaChanges($0) } == true)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func hasSchemaChangesIsTrueWhenAShippedMigrationsBodyChanges(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("schema")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var original = makeMigrator()
      original.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      try await original.migrate(driver)

      // The identifier never changed, but what it creates now has an extra column.
      var changed = makeMigrator()
      changed.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, note TEXT)")
      }

      #expect(try await driver.read { try changed.hasSchemaChanges($0) } == true)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func hasSchemaChangesIsTrueWhenAMigrationIsRegisteredBetweenTwoAlreadyAppliedOnes(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("schema")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var original = makeMigrator()
      original.registerMigration("one") { transaction in
        try transaction.execute("CREATE TABLE one_table (id INTEGER PRIMARY KEY)")
      }
      original.registerMigration("three") { transaction in
        try transaction.execute("CREATE TABLE three_table (id INTEGER PRIMARY KEY)")
      }
      try await original.migrate(driver)

      // GRDB's semantics: the scratch database migrates up to the last migration this database
      // has applied, "three", which runs "two" there even though it has never run here.
      var withInserted = makeMigrator()
      withInserted.registerMigration("one") { transaction in
        try transaction.execute("CREATE TABLE one_table (id INTEGER PRIMARY KEY)")
      }
      withInserted.registerMigration("two") { transaction in
        try transaction.execute("CREATE TABLE two_table (id INTEGER PRIMARY KEY)")
      }
      withInserted.registerMigration("three") { transaction in
        try transaction.execute("CREATE TABLE three_table (id INTEGER PRIMARY KEY)")
      }

      #expect(try await driver.read { try withInserted.hasSchemaChanges($0) } == true)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func hasSchemaChangesIgnoresWhatSQLiteKeepsForItselfAndTheMigratorsTable(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("schema")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var migrator = makeMigrator()
      migrator.registerMigration("Create counters") { transaction in
        try transaction.execute("CREATE TABLE counters (id INTEGER PRIMARY KEY AUTOINCREMENT)")
      }
      try await migrator.migrate(driver)

      // `sqlite_sequence` only appears once a row has been inserted, and the scratch database
      // this migrates never inserts one, so only the real database gets it.
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO counters DEFAULT VALUES")
      }
      #expect(try await driver.read { try migrator.hasSchemaChanges($0) } == false)

      #if !Turso
        // `ANALYZE` similarly leaves `sqlite_stat1` only in the real database; Turso does not
        // implement `ANALYZE`.
        try await driver.write { transaction in try transaction.execute("ANALYZE") }
        #expect(try await driver.read { try migrator.hasSchemaChanges($0) } == false)
      #endif
    }

    @Test
    func hasSchemaChangesWorksThroughEveryLentTypeIncludingAPoolsReadTransaction() async throws {
      let directory = try makeShortTemporaryDirectory("schema")
      defer { try? FileManager.default.removeItem(at: directory) }
      let pool = try SQLitePool(path: .file(directory.appending(component: "database.sqlite")))
      var original = makeMigrator()
      original.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      try await original.migrate(pool)

      var changed = makeMigrator()
      changed.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, note TEXT)")
      }

      // A pool's readers run with `PRAGMA query_only = 1`, which cf66808 kept out of what a
      // transaction reports as its configuration. Before that fix, the scratch database opened
      // from a reader's configuration would have inherited it and failed to migrate.
      #expect(try await pool.read { try changed.hasSchemaChanges($0) } == true)
      #expect(try await pool.readWithoutTransaction { try changed.hasSchemaChanges($0) } == true)
      #expect(try await pool.write { try changed.hasSchemaChanges($0) } == true)
      #expect(try await pool.writeWithoutTransaction { try changed.hasSchemaChanges($0) } == true)
      // The point-free form, relying on `hasSchemaChanges` specializing to whatever transaction
      // type the access lends.
      #expect(try await pool.read(changed.hasSchemaChanges) == true)
    }

    #if !Turso
      @Test
      func hasSchemaChangesCarriesRegisteredCollationsAndFunctionsToTheScratchDatabase()
        async throws
      {
        var configuration = SQLiteConfiguration.default
        // An index expression is schema-defined, so SQLite refuses a function it cannot trust
        // was not swapped out from under the schema unless it is told to trust it.
        configuration.isTrustedSchemaEnabled = true
        configuration.register(collation: $schemaChangeScratchCollation)
        configuration.register(function: $schemaChangeScratchDouble)
        let driver = try SQLiteQueue(path: .memory, configuration: configuration)
        var migrator = makeMigrator()
        migrator.registerMigration("Create words") { transaction in
          try transaction.execute(
            """
            CREATE TABLE words (
              id INTEGER PRIMARY KEY,
              text TEXT NOT NULL,
              value INTEGER NOT NULL
            );
            CREATE INDEX words_text ON words (text COLLATE schemaChangeScratchCollation);
            CREATE INDEX words_doubled ON words (schemaChangeScratchDouble(value));
            """
          )
        }
        try await migrator.migrate(driver)

        // The scratch database is opened with the same configuration, so it resolves the
        // collation and the function without error and reports the same schema back.
        #expect(try await driver.read { try migrator.hasSchemaChanges($0) } == false)
      }
    #endif

    @Test(arguments: SQLiteTestDriver.allCases)
    func hasSchemaChangesLeavesNoScratchDatabaseFilesBehind(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("schema")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var original = makeMigrator()
      original.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      try await original.migrate(driver)
      var changed = makeMigrator()
      changed.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, note TEXT)")
      }

      let before = try scratchDatabaseFileNames()
      _ = try await driver.read { try changed.hasSchemaChanges($0) }

      // This call's own scratch file is gone by the time it returns. Anything left matching the
      // pattern belongs to another test running in parallel, so wait for it to clean up its own
      // rather than assume this call is the only one running.
      try await waitUntil(timeout: .seconds(5)) {
        (try? scratchDatabaseFileNames().subtracting(before))?.isEmpty ?? false
      }
    }

    // MARK: Erasing

    @Test(arguments: SQLiteTestDriver.allCases)
    func erasingRunsEveryMigrationAgainDropsPriorDataAndResetsUserVersion(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("erase")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var original = makeMigrator()
      original.registerMigration("Create items") { transaction in
        try transaction.execute(
          "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
        )
      }
      original.registerMigration("Seed") { transaction in
        try transaction.execute("INSERT INTO items (id, title) VALUES (1, 'first')")
      }
      try await original.migrate(driver)
      // A non-zero value an application might set on its own, to check the erase resets it.
      try await driver.write { transaction in try transaction.execute("PRAGMA user_version = 7") }

      // The erase drops the log table along with everything else, so what ran is recorded here
      // instead.
      let secondRun = Lock([String]())
      var changed = makeMigrator()
      changed.eraseDatabaseOnSchemaChange = true
      changed.registerMigration("Create items") { transaction in
        secondRun.withLock { $0.append("Create items") }
        try transaction.execute(
          "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, note TEXT)"
        )
      }
      changed.registerMigration("Seed") { transaction in
        secondRun.withLock { $0.append("Seed") }
        try transaction.execute("INSERT INTO items (id, title) VALUES (2, 'second')")
      }

      try await changed.migrate(driver)

      // Detecting the change first migrates a scratch copy of the database to compare against,
      // which runs each migration there before the erase runs them again for real, so each
      // identifier appears rather than a run count pinned to that implementation detail.
      #expect(Set(secondRun.withLock { $0 }) == ["Create items", "Seed"])
      let ids = try await driver.read { transaction in
        try transaction.fetchAll(#sql("SELECT id FROM items", as: Int.self))
      }
      #expect(ids == [2])
      let columns = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
        )
      }
      #expect(columns == ["id", "title", "note"])
      let userVersion = try await driver.read { transaction in
        try transaction.fetchOne(#sql("PRAGMA user_version", as: Int.self))
      }
      #expect(userVersion == 0)
      #expect(
        try await driver.read { try changed.appliedMigrations($0) } == ["Create items", "Seed"]
      )
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func erasingRecreatesViewsTriggersAndIndexesWithoutError(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("erase")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var original = makeMigrator()
      original.registerMigration("Create items", migrate: createItemsWithViewAndTrigger)
      try await original.migrate(driver)

      var changed = makeMigrator()
      changed.eraseDatabaseOnSchemaChange = true
      changed.registerMigration("Create items") { transaction in
        try createItemsWithViewAndTrigger(transaction)
        try transaction.execute("ALTER TABLE items ADD COLUMN note TEXT")
      }

      try await changed.migrate(driver)

      let types = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql(
            "SELECT DISTINCT type FROM sqlite_schema WHERE type IN ('view', 'trigger', 'index')",
            as: String.self
          )
        )
      }
      #expect(Set(types) == ["view", "trigger", "index"])
      let columns = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
        )
      }
      #expect(columns == ["id", "title", "archived", "note"])
    }

    // Turso does not implement the FTS5 module: creating the virtual table fails with
    // "no such module: fts5", so this only runs against a build that has one.
    #if !Turso
      @Test(arguments: SQLiteTestDriver.allCases)
      func erasingRecreatesAnFTS5VirtualTableAndItsShadowTables(
        _ kind: SQLiteTestDriver
      ) async throws {
        let directory = try makeShortTemporaryDirectory("erase")
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = try kind.open(in: directory)
        var original = makeMigrator()
        original.registerMigration("Create documents") { transaction in
          try transaction.execute("CREATE VIRTUAL TABLE documents USING fts5(title)")
          try transaction.execute("INSERT INTO documents (title) VALUES ('hello world')")
        }
        try await original.migrate(driver)

        var changed = makeMigrator()
        changed.eraseDatabaseOnSchemaChange = true
        changed.registerMigration("Create documents") { transaction in
          try transaction.execute("CREATE VIRTUAL TABLE documents USING fts5(title, body)")
        }

        try await changed.migrate(driver)

        let columns = try await driver.read { transaction in
          try transaction.fetchAll(
            #sql("SELECT name FROM pragma_table_info('documents')", as: String.self)
          )
        }
        #expect(columns == ["title", "body"])
        // The old row, and the shadow tables that indexed it, are gone along with everything else.
        let matches = try await driver.read { transaction in
          try transaction.fetchOne(
            #sql("SELECT count(*) FROM documents WHERE documents MATCH 'hello'", as: Int.self)
          )
        }
        #expect(matches == 0)
      }
    #endif

    @Test(arguments: SQLiteTestDriver.allCases)
    func erasingATableOtherTablesReferToDoesNotFailOnForeignKeys(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("erase")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var original = makeMigrator()
      original.registerMigration("Create lists", migrate: createListsAndReminders)
      try await original.migrate(driver)

      var changed = makeMigrator()
      changed.eraseDatabaseOnSchemaChange = true
      changed.registerMigration("Create lists") { transaction in
        try createListsAndReminders(transaction)
        try transaction.execute("CREATE INDEX reminders_listID ON reminders (listID)")
      }

      try await changed.migrate(driver)

      let lists = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM lists", as: Int.self))
      }
      #expect(lists == 1)
      try await expectWriterForeignKeys(true, on: driver)
    }

    @Test
    func aFailedEraseLeavesTheDatabaseIntactAndRethrows() async throws {
      let driver = try SQLiteQueue(path: .memory)
      var original = makeMigrator()
      original.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try transaction.execute("INSERT INTO items (id) VALUES (1)")
      }
      try await original.migrate(driver)

      var changed = makeMigrator()
      changed.eraseDatabaseOnSchemaChange = true
      changed.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, note TEXT)")
      }

      // `PRAGMA query_only` turns the erase's `BEGIN IMMEDIATE` into a deferred transaction,
      // which fails the moment it tries to drop something, standing in for a disk that refuses
      // the write.
      let error = await #expect(throws: SQLiteError.self) {
        try await driver.writeWithoutTransaction { connection in
          try connection.execute("PRAGMA query_only = 1")
          defer { try? connection.execute("PRAGMA query_only = 0") }
          try changed.migrate(connection)
        }
      }
      #if !Turso
        #expect(error?.primaryCode == .readOnly)
      #else
        // Turso reports the same refusal as a generic error rather than SQLITE_READONLY.
        _ = error
      #endif

      let ids = try await driver.read { transaction in
        try transaction.fetchAll(#sql("SELECT id FROM items", as: Int.self))
      }
      #expect(ids == [1])
      let columns = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
        )
      }
      #expect(columns == ["id"])
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func migratingWithTheFlagOffLeavesAChangedSchemaAlone(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("erase")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var original = makeMigrator()
      original.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try transaction.execute("INSERT INTO items (id) VALUES (1)")
      }
      try await original.migrate(driver)

      var changed = makeMigrator()
      changed.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, note TEXT)")
      }

      #expect(!changed.eraseDatabaseOnSchemaChange)
      try await changed.migrate(driver)

      let columns = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
        )
      }
      #expect(columns == ["id"])
      let ids = try await driver.read { transaction in
        try transaction.fetchAll(#sql("SELECT id FROM items", as: Int.self))
      }
      #expect(ids == [1])
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func migratingAnUpToDateDatabaseWithTheFlagOnStillWritesAndAnnouncesNothing(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("erase")
      defer { try? FileManager.default.removeItem(at: directory) }
      try await checkUpToDateMigrationIsSilent(
        on: try kind.open(in: directory),
        eraseDatabaseOnSchemaChange: true
      )
    }

    @Test
    func anUnregisteredTargetWithTheFlagOnThrowsBeforeErasingAnything() async throws {
      let driver = try SQLiteQueue(path: .memory)
      var original = makeMigrator()
      original.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try transaction.execute("INSERT INTO items (id) VALUES (1)")
      }
      try await original.migrate(driver)

      var changed = makeMigrator()
      changed.eraseDatabaseOnSchemaChange = true
      changed.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, note TEXT)")
      }

      let error = await #expect(throws: OrbitDatabaseMigrationTargetError.self) {
        try await changed.migrate(driver, upTo: "missing")
      }
      #expect(error == OrbitDatabaseMigrationTargetError(target: "missing", reason: .unregistered))

      let columns = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
        )
      }
      #expect(columns == ["id"])
      let ids = try await driver.read { transaction in
        try transaction.fetchAll(#sql("SELECT id FROM items", as: Int.self))
      }
      #expect(ids == [1])
    }

    @Test
    func anAppliedMigrationThisMigratorDoesNotRegisterErasesWithTheFlagOnAsDocumented()
      async throws
    {
      let driver = try SQLiteQueue(path: .memory)
      var newerBuild = makeMigrator()
      newerBuild.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try transaction.execute("INSERT INTO items (id) VALUES (1)")
      }
      newerBuild.registerMigration("Add notes") { transaction in
        try transaction.execute("ALTER TABLE items ADD COLUMN note TEXT")
      }
      try await newerBuild.migrate(driver)

      // An older build that has not shipped "Add notes" yet. With the flag on, this is
      // documented to erase, exactly as a removed migration would.
      var olderBuild = makeMigrator()
      olderBuild.eraseDatabaseOnSchemaChange = true
      olderBuild.registerMigration("Create items") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }

      try await olderBuild.migrate(driver)

      let ids = try await driver.read { transaction in
        try transaction.fetchAll(#sql("SELECT id FROM items", as: Int.self))
      }
      #expect(ids == [])
      let columns = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
        )
      }
      #expect(columns == ["id"])
      #expect(try await driver.read { try olderBuild.appliedMigrations($0) } == ["Create items"])
    }

    @Test
    func twoPoolsMigratingConcurrentlyWithTheFlagOnAgreeOnOneErasedResult() async throws {
      let directory = try makeShortTemporaryDirectory("erase")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))

      var original = makeMigrator()
      original.registerMigration("Create runs") { transaction in
        try transaction.execute(
          "CREATE TABLE runs (migration TEXT NOT NULL); INSERT INTO runs VALUES ('old')"
        )
      }
      do {
        let seeder = try SQLiteQueue(path: path)
        try await original.migrate(seeder)
      }

      var changed = makeMigrator()
      changed.eraseDatabaseOnSchemaChange = true
      changed.registerMigration("Create runs") { transaction in
        try transaction.execute(
          """
          CREATE TABLE runs (migration TEXT NOT NULL, note TEXT);
          INSERT INTO runs (migration) VALUES ('Create runs');
          """
        )
      }
      for index in 1...5 {
        let identifier = "Migration \(index)"
        changed.registerMigration(identifier) { transaction in
          try transaction.execute(
            #sql("INSERT INTO runs (migration) VALUES (\(bind: identifier))", as: Void.self)
          )
        }
      }

      let first = try SQLitePool(path: path)
      let second = try SQLitePool(path: path)
      // A `let` copy, since a mutable variable cannot be sent into two concurrent `async let`s.
      let migrator = changed

      async let firstRun: Void = migrator.migrate(first)
      async let secondRun: Void = migrator.migrate(second)
      _ = try await (firstRun, secondRun)

      let expected = ["Create runs"] + (1...5).map { "Migration \($0)" }
      let runs = try await first.read { transaction in
        try transaction.fetchAll(#sql("SELECT migration FROM runs ORDER BY rowid", as: String.self))
      }
      #expect(runs == expected)
      #expect(try await first.read { try migrator.appliedMigrations($0) } == expected)
      let columns = try await first.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('runs')", as: String.self)
        )
      }
      #expect(columns == ["migration", "note"])
    }

    #if Turso
      @Test
      func autoincrementTablesEraseAndRecreateCleanlyOnTurso() async throws {
        // Turso keeps its own `__turso_internal_seq_<table>` in place of `sqlite_sequence`, which
        // must be left out of the comparison the same way.
        let directory = try makeShortTemporaryDirectory("turso-erase")
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = try SQLiteQueue(
          path: .file(directory.appending(component: "database.sqlite"))
        )
        var migrator = makeMigrator()
        migrator.registerMigration("Create counters") { transaction in
          try transaction.execute("CREATE TABLE counters (id INTEGER PRIMARY KEY AUTOINCREMENT)")
          try transaction.execute("INSERT INTO counters DEFAULT VALUES")
        }
        try await migrator.migrate(driver)

        #expect(try await driver.read { try migrator.hasSchemaChanges($0) } == false)

        var changed = makeMigrator()
        changed.eraseDatabaseOnSchemaChange = true
        changed.registerMigration("Create counters") { transaction in
          try transaction.execute(
            "CREATE TABLE counters (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT)"
          )
          try transaction.execute("INSERT INTO counters DEFAULT VALUES")
        }

        try await changed.migrate(driver)

        let columns = try await driver.read { transaction in
          try transaction.fetchAll(
            #sql("SELECT name FROM pragma_table_info('counters')", as: String.self)
          )
        }
        #expect(columns == ["id", "note"])
        let ids = try await driver.read { transaction in
          try transaction.fetchAll(#sql("SELECT id FROM counters", as: Int.self))
        }
        #expect(ids == [1])
      }
    #endif

    #if SQLCipher
      @Test
      func hasSchemaChangesAndEraseWorkOnAnEncryptedDatabase() async throws {
        let path = temporaryDatabasePath("migrator-cipher")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let configuration = SQLiteConfiguration.sqlCipher(key: .passphrase("open sesame"))
        let driver = try SQLiteQueue(
          path: .file(URL(fileURLWithPath: path)),
          configuration: configuration
        )

        var original = makeMigrator()
        original.registerMigration("Create items") { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
          try transaction.execute("INSERT INTO items (id) VALUES (1)")
        }
        try await original.migrate(driver)
        #expect(try await driver.read { try original.hasSchemaChanges($0) } == false)

        // The scratch database `hasSchemaChanges` opens is keyed the same way, or it could not
        // even read the real one's schema to compare against.
        var changed = makeMigrator()
        changed.eraseDatabaseOnSchemaChange = true
        changed.registerMigration("Create items") { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, note TEXT)")
        }
        #expect(try await driver.read { try changed.hasSchemaChanges($0) } == true)

        try await changed.migrate(driver)

        let columns = try await driver.read { transaction in
          try transaction.fetchAll(
            #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
          )
        }
        #expect(columns == ["id", "note"])
        let ids = try await driver.read { transaction in
          try transaction.fetchAll(#sql("SELECT id FROM items", as: Int.self))
        }
        #expect(ids == [])
      }
    #endif
  }

  // MARK: - Support

  /// `base`, set up so that the deferred migrations registered on it run under every trait.
  ///
  /// Turso cannot check foreign keys before a migration commits, so it refuses a deferred migration
  /// that would be checked. A test that is not about the check registers its migrations unchecked
  /// there, which still runs them with foreign keys off, as on every other build.
  func makeMigrator(_ base: OrbitDatabaseMigrator = OrbitDatabaseMigrator())
    -> OrbitDatabaseMigrator
  {
    var migrator = base
    #if Turso
      migrator.defersForeignKeyChecks = false
    #endif
    return migrator
  }

  /// A migrator whose migrations each record that they ran, for checking that concurrent runs
  /// apply every migration exactly once.
  func makeContendedMigrator() -> OrbitDatabaseMigrator {
    var migrator = makeMigrator()
    migrator.registerMigration("Create runs") { transaction in
      try transaction.execute(
        """
        CREATE TABLE runs (migration TEXT NOT NULL);
        INSERT INTO runs VALUES ('Create runs');
        """
      )
    }
    for index in 1...10 {
      let identifier = "Migration \(index)"
      migrator.registerMigration(identifier) { transaction in
        try transaction.execute(
          #sql("INSERT INTO runs (migration) VALUES (\(bind: identifier))", as: Void.self)
        )
      }
    }
    return migrator
  }

  func expectContendedMigrationsAppliedOnce(in writer: some OrbitDatabaseWriter) async throws {
    let migrator = makeContendedMigrator()
    let (runs, applied) = try await writer.read { transaction in
      (
        try transaction.fetchAll(
          #sql("SELECT migration FROM runs ORDER BY rowid", as: String.self)
        ),
        try migrator.appliedMigrations(transaction)
      )
    }
    let expected = ["Create runs"] + (1...10).map { "Migration \($0)" }
    #expect(runs == expected)
    #expect(applied == expected)
  }

  private func loggingMigrator(
    _ identifiers: [String],
    eraseDatabaseOnSchemaChange: Bool = false
  ) -> OrbitDatabaseMigrator {
    var migrator = makeMigrator()
    migrator.eraseDatabaseOnSchemaChange = eraseDatabaseOnSchemaChange
    for identifier in identifiers {
      migrator.registerMigration(identifier) { transaction in
        try transaction.execute("CREATE TABLE IF NOT EXISTS log (identifier TEXT NOT NULL)")
        try transaction.execute(
          #sql("INSERT INTO log (identifier) VALUES (\(bind: identifier))", as: Void.self)
        )
      }
    }
    return migrator
  }

  private func log(in reader: some OrbitDatabaseReader) async throws -> [String] {
    try await reader.read { transaction in
      try transaction.fetchAll(#sql("SELECT identifier FROM log ORDER BY rowid", as: String.self))
    }
  }

  private func createListsAndReminders(_ transaction: borrowing SQLiteWriteTransaction) throws {
    try transaction.execute(
      """
      CREATE TABLE lists (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
      CREATE TABLE reminders (
        id INTEGER PRIMARY KEY,
        listID INTEGER NOT NULL REFERENCES lists (id) ON DELETE CASCADE
      );
      INSERT INTO lists VALUES (1, 'Errands');
      INSERT INTO reminders VALUES (1, 1), (2, 1);
      """
    )
  }

  private func foreignKeysPragma(in transaction: borrowing SQLiteWriteTransaction) throws -> Int {
    try transaction.fetchOne(#sql("PRAGMA foreign_keys", as: Int.self)) ?? -1
  }

  private func createItemsWithViewAndTrigger(
    _ transaction: borrowing SQLiteWriteTransaction
  ) throws {
    try transaction.execute(
      """
      CREATE TABLE items (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX items_title ON items (title);
      CREATE VIEW active_items AS SELECT * FROM items WHERE archived = 0;
      CREATE TRIGGER items_archived AFTER UPDATE OF archived ON items WHEN NEW.archived = 1 BEGIN
        UPDATE items SET title = title || ' (archived)' WHERE id = NEW.id;
      END;
      """
    )
  }

  /// Every file `hasSchemaChanges` leaves a scratch database under, currently on disk.
  ///
  /// - Parameter directory: Where to look; the system temporary directory by default.
  private func scratchDatabaseFileNames(
    in directory: URL = FileManager.default.temporaryDirectory
  ) throws -> Set<String> {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return Set(names.filter { $0.hasPrefix("SQLiteOrbit-migrator-") })
  }

  #if !Turso
    // Custom collations and functions are unavailable on Turso, so these exist only for the test
    // that checks the scratch database `hasSchemaChanges` builds gets the same ones registered.

    @DatabaseCollation
    private func schemaChangeScratchCollation(_ lhs: String, _ rhs: String) -> CollationOrder {
      CollationOrder(String(lhs.reversed()), String(rhs.reversed()))
    }

    @DatabaseFunction(isDeterministic: true)
    private func schemaChangeScratchDouble(_ value: Int) -> Int { value * 2 }
  #endif

  /// Checks that foreign keys on the connection migrations run on are as `isEnabled` says, both as
  /// the connection tracks them and as SQLite reports them.
  private func expectWriterForeignKeys(
    _ isEnabled: Bool,
    on writer: some OrbitDatabaseWriter,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let (tracked, pragma) = try await writer.writeWithoutTransaction { connection in
      (
        connection.isForeignKeysEnabled,
        try connection.fetchOne(#sql("PRAGMA foreign_keys", as: Int.self))
      )
    }
    #expect(tracked == isEnabled, sourceLocation: sourceLocation)
    #expect(pragma == (isEnabled ? 1 : 0), sourceLocation: sourceLocation)
  }

  /// Reads a pragma from the connection that migrations run on, which in a pool is not one of the
  /// connections reads are served from.
  private func writerPragma(
    _ name: String,
    on writer: some OrbitDatabaseWriter
  ) async throws -> Int? {
    try await writer.writeWithoutTransaction { connection in
      try connection.fetchOne(SQLQueryExpression("PRAGMA \(raw: name)", as: Int.self))
    }
  }

  private struct Inspection: Equatable, Sendable {
    var identifiers: Set<String>
    var applied: [String]
    var completed: [String]
    var hasCompleted: Bool
    var hasBeenSuperseded: Bool

    init(
      identifiers: Set<String>,
      applied: [String],
      completed: [String],
      hasCompleted: Bool,
      hasBeenSuperseded: Bool
    ) {
      self.identifiers = identifiers
      self.applied = applied
      self.completed = completed
      self.hasCompleted = hasCompleted
      self.hasBeenSuperseded = hasBeenSuperseded
    }

    init<Transaction>(
      of migrator: OrbitDatabaseMigrator,
      in transaction: borrowing Transaction
    ) throws
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable
    {
      self.identifiers = try migrator.appliedIdentifiers(transaction)
      self.applied = try migrator.appliedMigrations(transaction)
      self.completed = try migrator.completedMigrations(transaction)
      self.hasCompleted = try migrator.hasCompletedMigrations(transaction)
      self.hasBeenSuperseded = try migrator.hasBeenSuperseded(transaction)
    }
  }

  private final class MigrationEventObserver: OrbitDatabaseTransactionObserver, Sendable {
    private struct Counts {
      var commits = 0
      var events = 0
    }

    private let counts = Lock(Counts())

    var commitCount: Int { counts.withLock { $0.commits } }
    var eventCount: Int { counts.withLock { $0.events } }

    func databaseDidChange(in region: OrbitDatabaseRegion) {
      counts.withLock { $0.events += 1 }
    }

    func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
      counts.withLock { counts in
        counts.commits += 1
        counts.events += 1
      }
    }

    func databaseDidRollback() {
      counts.withLock { $0.events += 1 }
    }
  }
#endif
