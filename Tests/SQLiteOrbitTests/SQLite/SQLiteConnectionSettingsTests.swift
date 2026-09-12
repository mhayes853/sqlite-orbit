#if BuiltInSQLite
  import Foundation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteConnectionSettingsTests {
    // MARK: - Busy timeout

    @Test(arguments: SQLiteTestDriver.allCases)
    func busyTimeoutChangedByAWriteConnectionIsRestoredWhenTheAccessEnds(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try kind.open(in: directory, configuration: singleReaderConfiguration())

      let during = try await driver.writeWithoutTransaction { connection in
        #expect(connection.busyTimeout == .limit(.seconds(5)))
        connection.busyTimeout = .limit(.seconds(42))
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

    @Test(arguments: SQLiteTestDriver.allCases)
    func busyTimeoutChangedByAReadConnectionIsRestoredWhenTheAccessEnds(
      _ kind: SQLiteTestDriver
    ) async throws {
      struct Abort: Error {}

      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      // One reader, so that every read lands on the connection the first one changed.
      let driver = try kind.open(in: directory, configuration: singleReaderConfiguration())

      let during = try await driver.readWithoutTransaction { connection in
        connection.busyTimeout = .maximum
        #expect(connection.busyTimeout == .maximum)
        return try connection.fetchOne(busyTimeout)
      }
      #expect(during == Int(Int32.max))
      #expect(try await driver.read { try $0.fetchOne(busyTimeout) } == 5000)

      // A body that throws has its change put back all the same.
      await #expect(throws: Abort.self) {
        try await driver.readWithoutTransaction { connection in
          connection.busyTimeout = .limit(.milliseconds(1))
          throw Abort()
        }
      }
      let after = try await driver.readWithoutTransaction { connection in
        #expect(connection.busyTimeout == .limit(.seconds(5)))
        return try connection.fetchOne(busyTimeout)
      }
      #expect(after == 5000)
    }

    // MARK: - Foreign keys

    @Test(arguments: SQLiteTestDriver.allCases)
    func foreignKeysTurnedOffAreRestoredWhenTheAccessEnds(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try await kind.openWithLists(in: directory)

      let during = try await driver.writeWithoutTransaction { connection in
        let wasEnabled = connection.isForeignKeysEnabled
        connection.isForeignKeysEnabled = false
        #expect(wasEnabled && !connection.isForeignKeysEnabled)
        // With enforcement off the orphan is accepted, which the pragma alone would not show.
        try connection.transaction { transaction in _ = try transaction.execute(orphan) }
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

    @Test(arguments: SQLiteTestDriver.allCases)
    func foreignKeysChangeBeforeTheNextStatementOrTransaction(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let probe = PragmaProbe()
      let driver = try await kind.openWithLists(in: directory, probe: probe)

      try await driver.writeWithoutTransaction { connection in
        // Setting runs nothing, and reading returns what was set.
        connection.isForeignKeysEnabled = false
        #expect(probe.foreignKeysChanges.isEmpty)
        let isEnabled = connection.isForeignKeysEnabled
        #expect(!isEnabled)

        // A cursor, and so every fetch built on one.
        #expect(try connection.fetchOne(foreignKeys) == 0)
        #expect(probe.foreignKeysChanges == ["PRAGMA foreign_keys = 0"])

        // A transaction, before it begins: the pragma would be ignored once it had.
        connection.isForeignKeysEnabled = true
        #expect(try connection.transaction { try $0.fetchOne(foreignKeys) } == 1)

        // Both kinds of `execute`, which the orphan is refused or accepted by.
        connection.isForeignKeysEnabled = false
        try connection.execute("INSERT INTO entries (id, listID) VALUES (1, 1)")
        connection.isForeignKeysEnabled = true
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

    @Test(arguments: SQLiteTestDriver.allCases)
    func aChangeUndoneBeforeAnyStatementRunsNoPragma(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let probe = PragmaProbe()
      let driver = try await kind.openWithLists(in: directory, probe: probe)

      try await driver.writeWithoutTransaction { connection in
        connection.isForeignKeysEnabled = false
        connection.isForeignKeysEnabled = true
        _ = try connection.fetchOne(foreignKeys)
      }
      // A change left pending when the access ends never reached SQLite, so nothing undoes it.
      try await driver.writeWithoutTransaction { connection in
        connection.isForeignKeysEnabled = false
      }

      #expect(probe.foreignKeysChanges.isEmpty)
      #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func aFailedChangeIsThrownByTheNextStatementAndStaysPending(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let probe = PragmaProbe(failing: "PRAGMA foreign_keys = 0")
      let driver = try await kind.openWithLists(in: directory, probe: probe)
      probe.isFailing = true

      let (isEnabledAfterFailure, during) = try await driver.writeWithoutTransaction { connection in
        connection.isForeignKeysEnabled = false
        let error = #expect(throws: SQLiteError.self) { try connection.fetchOne(foreignKeys) }
        #expect(error?.sql == "PRAGMA foreign_keys = 0")
        // Still pending, so a transaction tries again before it begins and fails the same way.
        let ran = Lock(false)
        #expect(throws: SQLiteError.self) {
          try connection.transaction { _ in ran.withLock { $0 = true } }
        }
        #expect(!ran.withLock { $0 })
        let isEnabledAfterFailure = connection.isForeignKeysEnabled

        probe.isFailing = false
        return (isEnabledAfterFailure, try connection.fetchOne(foreignKeys))
      }

      #expect(!isEnabledAfterFailure)
      #expect(during == 0)
      #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func foreignKeysAreRestoredWhenTheBodyThrows(_ kind: SQLiteTestDriver) async throws {
      struct Abort: Error {}

      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try await kind.openWithLists(in: directory)

      await #expect(throws: Abort.self) {
        try await driver.writeWithoutTransaction { connection in
          connection.isForeignKeysEnabled = false
          _ = try connection.fetchOne(foreignKeys)
          throw Abort()
        }
      }

      #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func foreignKeysAreRestoredAfterATransactionLeftOpenIsRolledBack(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try await kind.openWithLists(in: directory)
      let savepoint = #sql("SAVEPOINT leftover", as: Void.self)

      try await driver.writeWithoutTransaction { connection in
        connection.isForeignKeysEnabled = false
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

    @Test(arguments: SQLiteTestDriver.allCases)
    func foreignKeysConfiguredOffAreRestoredToOff(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      var configuration = SQLiteConfiguration.default
      configuration.isForeignKeysEnabled = false
      let driver = try kind.open(in: directory, configuration: configuration)

      let (wasEnabled, during) = try await driver.writeWithoutTransaction { connection in
        let wasEnabled = connection.isForeignKeysEnabled
        connection.isForeignKeysEnabled = true
        return (wasEnabled, try connection.fetchOne(foreignKeys))
      }

      #expect(!wasEnabled)
      #expect(during == 1)
      #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 0)
    }

    // Exit tests run the test in a child process, which only these platforms can spawn.
    #if os(macOS) || os(Linux) || os(Windows)
      @Test
      func changingForeignKeysInsideTheConnectionsTransactionStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
          let driver = try SQLiteQueue(path: .memory)
          try driver.writeWithoutTransactionBlocking { connection in
            try connection.transaction { _ in
              connection.isForeignKeysEnabled = false
            }
          }
        }
      }
    #endif

    // MARK: - Failed restores

    @Test(arguments: SQLiteTestDriver.allCases)
    func aFailedRestoreFailsTheAccessAndIsRetriedByTheNextOne(
      _ kind: SQLiteTestDriver
    ) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let probe = PragmaProbe(failing: "PRAGMA foreign_keys = 1")
      let driver = try await kind.openWithLists(in: directory, probe: probe)
      probe.isFailing = true

      // The body succeeded, so the restore's failure is what the access reports.
      let error = await #expect(throws: SQLiteError.self) {
        try await driver.writeWithoutTransaction { connection in
          connection.isForeignKeysEnabled = false
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

    @Test(arguments: SQLiteTestDriver.allCases)
    func aFailedRestoreDoesNotMaskTheBodysError(_ kind: SQLiteTestDriver) async throws {
      struct Abort: Error {}

      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let probe = PragmaProbe(failing: "PRAGMA foreign_keys = 1")
      let driver = try await kind.openWithLists(in: directory, probe: probe)
      probe.isFailing = true

      await #expect(throws: Abort.self) {
        try await driver.writeWithoutTransaction { connection in
          connection.isForeignKeysEnabled = false
          _ = try connection.fetchOne(foreignKeys)
          throw Abort()
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
        _ = try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      let count = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
      }
      #expect(count == 1)
    }
  }

  extension SQLiteTestDriver {
    fileprivate func open(
      in directory: URL,
      configuration: SQLiteConfiguration
    ) throws -> any OrbitObservableDatabase {
      switch self {
      case .queue: try SQLiteQueue(path: path(in: directory), configuration: configuration)
      case .pool: try SQLitePool(path: path(in: directory), configuration: configuration)
      }
    }

    fileprivate func openWithLists(
      in directory: URL,
      probe: PragmaProbe? = nil
    ) async throws -> any OrbitObservableDatabase {
      let driver = try open(
        in: directory,
        configuration: probe?.configuration() ?? .default
      )
      try await driver.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE lists (id INTEGER PRIMARY KEY);
          CREATE TABLE entries (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists (id));
          """
        )
      }
      return driver
    }
  }

  /// Records the foreign keys changes a connection runs, and makes one pragma fail while switched
  /// on, standing in for a pragma SQLite refuses.
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
      configuration.readerCount = 1
      configuration.library.statements.execution.step = { [self] statement in
        guard let text = base.statements.inspection.sql(statement) else {
          return base.statements.execution.step(statement)
        }
        let sql = String(cString: text)
        // Configuring the connection spells the pragma `ON` or `OFF`, which this leaves out.
        if sql.hasPrefix("PRAGMA foreign_keys = "), sql.last?.isNumber == true {
          changes.withLock { $0.append(sql) }
        }
        if isFailing, sql == failingSQL {
          return SQLiteResultCode.ioError.rawValue
        }
        return base.statements.execution.step(statement)
      }
      return configuration
    }
  }

  private func singleReaderConfiguration() -> SQLiteConfiguration {
    var configuration = SQLiteConfiguration.default
    configuration.readerCount = 1
    return configuration
  }

  private let busyTimeout = #sql("PRAGMA busy_timeout", as: Int.self)
  private let foreignKeys = #sql("PRAGMA foreign_keys", as: Int.self)
  private let orphan = #sql("INSERT INTO entries (id, listID) VALUES (1, 1)", as: Void.self)
  private let secondOrphan = #sql("INSERT INTO entries (id, listID) VALUES (2, 2)", as: Void.self)
#endif
