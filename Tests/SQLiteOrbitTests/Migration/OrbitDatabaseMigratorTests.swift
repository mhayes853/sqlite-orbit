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
        try await driver.read { try migrator.appliedMigrations(in: $0) } == ["one", "two", "three"]
      )
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
      on writer: some OrbitObservableDatabase
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
      let migrator = loggingMigrator(["one", "two"])

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
      #expect(try await driver.read { try migrator.appliedIdentifiers(in: $0) }.isEmpty)
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
      var migrator = OrbitDatabaseMigrator()
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
      #expect(try await writerPragma("foreign_keys", on: driver) == 1)
    }

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
        try await driver.read { try migrator.appliedMigrations(in: $0) } == ["Create lists"]
      )
      let reminders = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM reminders", as: Int.self))
      }
      #expect(reminders == 2)
      #expect(try await writerPragma("foreign_keys", on: driver) == 1)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func immediateChecksKeepForeignKeysOnDuringTheMigration(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      let foreignKeys = Lock([Int]())
      var migrator = OrbitDatabaseMigrator()
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
        try await driver.read { try migrator.appliedMigrations(in: $0) } == ["Create lists"]
      )
    }

    @Test
    func disablingDeferredChecksSkipsTheCheckOfLaterMigrationsOnly() async throws {
      let foreignKeys = Lock([Int]())
      var migrator = OrbitDatabaseMigrator()
      migrator.registerMigration("Create lists", migrate: createListsAndReminders)
      var checked = migrator
      checked.registerMigration("Checked orphan") { transaction in
        try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
      }
      migrator = migrator.disablingDeferredForeignKeyChecks()
      migrator.registerMigration("Unchecked orphan") { transaction in
        try foreignKeys.withLock { $0.append(try foreignKeysPragma(in: transaction)) }
        try transaction.execute("INSERT INTO reminders (id, listID) VALUES (3, 7)")
      }

      let uncheckedDriver = try SQLiteQueue(path: .memory)
      try await migrator.migrate(uncheckedDriver)
      #expect(foreignKeys.withLock { $0 } == [0])
      #expect(try await writerPragma("foreign_keys", on: uncheckedDriver) == 1)
      let orphans = try await uncheckedDriver.read { transaction in
        try transaction.fetchAll(#sql("PRAGMA foreign_key_check", as: String.self))
      }
      #expect(orphans == ["reminders"])

      let checkedDriver = try SQLiteQueue(path: .memory)
      let checkedMigrator = checked.disablingDeferredForeignKeyChecks()
      await #expect(throws: OrbitDatabaseForeignKeyViolationError.self) {
        try await checkedMigrator.migrate(checkedDriver)
      }
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
      #expect(try await writerPragma("foreign_keys", on: driver) == 0)
      #expect(try await driver.read { try migrator.hasCompletedMigrations(in: $0) })
    }

    // MARK: - The table of applied migrations

    @Test(arguments: SQLiteTestDriver.allCases)
    func customTableNameIsQuotedAndUsedInsteadOfTheDefault(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var migrator = OrbitDatabaseMigrator(tableName: #"app "migrations""#)
      migrator.registerMigration("one") { _ in }

      try await migrator.migrate(driver)

      let tables = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name", as: String.self)
        )
      }
      #expect(tables == [#"app "migrations""#])
      #expect(try await driver.read { try migrator.appliedIdentifiers(in: $0) } == ["one"])
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
      var migrator = OrbitDatabaseMigrator(tableName: "grdb_migrations")
      migrator.registerMigration("v1") { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      migrator.registerMigration("v2") { transaction in
        try transaction.execute("ALTER TABLE items ADD COLUMN title TEXT")
      }

      try await migrator.migrate(driver)

      #expect(try await driver.read { try migrator.appliedMigrations(in: $0) } == ["v1", "v2"])
      let columns = try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT name FROM pragma_table_info('items')", as: String.self)
        )
      }
      #expect(columns == ["id", "title"])
    }

    // MARK: - Pragmas

    @Test(arguments: SQLiteTestDriver.allCases)
    func failingMigrationRethrowsItsErrorAndRestoresPragmas(
      _ kind: SQLiteTestDriver
    ) async throws {
      struct MigrationFailure: Error, Equatable {}

      let directory = try makeShortTemporaryDirectory("migrate")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory)
      var migrator = OrbitDatabaseMigrator()
      migrator.busyTimeout = .limit(.seconds(42))
      migrator.registerMigration("one") { _ in }
      migrator.registerMigration("two") { transaction in
        try transaction.execute("CREATE TABLE doomed (id INTEGER)")
        throw MigrationFailure()
      }

      let error = await #expect(throws: MigrationFailure.self) {
        try await migrator.migrate(driver)
      }

      #expect(error == MigrationFailure())
      #expect(try await writerPragma("foreign_keys", on: driver) == 1)
      #expect(try await writerPragma("busy_timeout", on: driver) == 5000)
      #expect(try await driver.read { try migrator.appliedMigrations(in: $0) } == ["one"])
    }

    @Test(arguments: [
      (OrbitDatabaseMigrator.BusyTimeout.limit(.milliseconds(1234)), 1234),
      (.unlimited, Int(Int32.max)),
      (.configured, 5000)
    ])
    func busyTimeoutOverrideAppliesDuringTheRunOnly(
      _ busyTimeout: OrbitDatabaseMigrator.BusyTimeout,
      _ expected: Int
    ) async throws {
      let driver = try SQLiteQueue(path: .memory)
      let observed = Lock<Int?>(nil)
      var migrator = OrbitDatabaseMigrator()
      migrator.busyTimeout = busyTimeout
      migrator.registerMigration("one") { transaction in
        let value = try transaction.fetchOne(#sql("PRAGMA busy_timeout", as: Int.self))
        observed.withLock { $0 = value }
      }

      try await migrator.migrate(driver)

      #expect(observed.withLock { $0 } == expected)
      #expect(try await writerPragma("busy_timeout", on: driver) == 5000)
    }

    @Test
    func cancellingStopsOnAMigrationBoundaryAndRestoresPragmas() async throws {
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
      var migrator = OrbitDatabaseMigrator()
      migrator.busyTimeout = .unlimited
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

      let running = Task { [migrator] in try await migrator.migrate(driver) }
      try await waitUntil { steps.withLock { $0 } > 0 }
      running.cancel()

      await #expect(throws: CancellationError.self) {
        try await running.value
      }
      #expect(try await driver.read { try migrator.appliedMigrations(in: $0) } == ["one"])
      let items = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
      }
      #expect(items == 0)
      #expect(try await writerPragma("foreign_keys", on: driver) == 1)
      #expect(try await writerPragma("busy_timeout", on: driver) == 5000)
    }

    // MARK: - Busy databases

    @Test
    func busyTransactionIsRetriedAFewTimes() async throws {
      let begins = Lock(0)
      let busyBegins = Lock(0)
      let base = builtInTestLibrary
      var configuration = SQLiteConfiguration.default
      configuration.library = base
      configuration.library.statements.execution.step = { statement in
        if let sql = base.statements.inspection.sql(statement),
          String(cString: sql).hasPrefix("BEGIN IMMEDIATE")
        {
          let attempt = begins.withLock { count in
            count += 1
            return count
          }
          if attempt <= busyBegins.withLock({ $0 }) {
            return SQLiteResultCode.busy.rawValue
          }
        }
        return base.statements.execution.step(statement)
      }
      let driver = try SQLiteQueue(path: .memory, configuration: configuration)
      let migrator = loggingMigrator(["one"])

      busyBegins.withLock { $0 = 3 }
      try await migrator.migrate(driver)
      #expect(begins.withLock { $0 } == 4)
      #expect(try await log(in: driver) == ["one"])

      let later = loggingMigrator(["one", "two"])
      begins.withLock { $0 = 0 }
      busyBegins.withLock { $0 = .max }
      let error = await #expect(throws: SQLiteError.self) {
        try await later.migrate(driver)
      }
      #expect(error?.primaryCode == .busy)
      #expect(begins.withLock { $0 } == 4)
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
        .tracking { try migrator.appliedMigrations(in: $0) }
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
  }

  // MARK: - Support

  /// A migrator whose migrations each record that they ran, for checking that concurrent runs
  /// apply every migration exactly once.
  func makeContendedMigrator() -> OrbitDatabaseMigrator {
    var migrator = OrbitDatabaseMigrator()
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
        try migrator.appliedMigrations(in: transaction)
      )
    }
    let expected = ["Create runs"] + (1...10).map { "Migration \($0)" }
    #expect(runs == expected)
    #expect(applied == expected)
  }

  private func loggingMigrator(_ identifiers: [String]) -> OrbitDatabaseMigrator {
    var migrator = OrbitDatabaseMigrator()
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
      self.identifiers = try migrator.appliedIdentifiers(in: transaction)
      self.applied = try migrator.appliedMigrations(in: transaction)
      self.completed = try migrator.completedMigrations(in: transaction)
      self.hasCompleted = try migrator.hasCompletedMigrations(in: transaction)
      self.hasBeenSuperseded = try migrator.hasBeenSuperseded(in: transaction)
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
