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
        connection.busyTimeout = .unlimited
        #expect(connection.busyTimeout == .unlimited)
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
        try connection.setForeignKeysEnabled(false)
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
    func foreignKeysAreRestoredWhenTheBodyThrows(_ kind: SQLiteTestDriver) async throws {
      struct Abort: Error {}

      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      let driver = try await kind.openWithLists(in: directory)

      await #expect(throws: Abort.self) {
        try await driver.writeWithoutTransaction { connection in
          try connection.setForeignKeysEnabled(false)
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

    @Test(arguments: SQLiteTestDriver.allCases)
    func foreignKeysConfiguredOffAreRestoredToOff(_ kind: SQLiteTestDriver) async throws {
      let directory = try makeShortTemporaryDirectory("settings")
      defer { try? FileManager.default.removeItem(at: directory) }
      var configuration = SQLiteConfiguration.default
      configuration.isForeignKeysEnabled = false
      let driver = try kind.open(in: directory, configuration: configuration)

      let (wasEnabled, during) = try await driver.writeWithoutTransaction { connection in
        let wasEnabled = connection.isForeignKeysEnabled
        try connection.setForeignKeysEnabled(true)
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
              try connection.setForeignKeysEnabled(false)
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
      let failing = FailingStatement("PRAGMA foreign_keys = 1")
      let driver = try await kind.openWithLists(in: directory, failing: failing)
      failing.isFailing = true

      // The body succeeded, so the restore's failure is what the access reports.
      let error = await #expect(throws: SQLiteError.self) {
        try await driver.writeWithoutTransaction { connection in
          try connection.setForeignKeysEnabled(false)
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

      failing.isFailing = false
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
      let failing = FailingStatement("PRAGMA foreign_keys = 1")
      let driver = try await kind.openWithLists(in: directory, failing: failing)
      failing.isFailing = true

      await #expect(throws: Abort.self) {
        try await driver.writeWithoutTransaction { connection in
          try connection.setForeignKeysEnabled(false)
          throw Abort()
        }
      }

      // The setting stayed marked as changed, so the next access restores it before it begins.
      failing.isFailing = false
      #expect(try await driver.write { try $0.fetchOne(foreignKeys) } == 1)
    }

    @Test
    func aFailedQueryOnlyRestoreHoldsBackTheNextWrite() async throws {
      let failing = FailingStatement("PRAGMA query_only = 0")
      let driver = try SQLiteQueue(path: .memory, configuration: failing.configuration())
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      failing.isFailing = true

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

      failing.isFailing = false
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
      failing: FailingStatement? = nil
    ) async throws -> any OrbitObservableDatabase {
      let driver = try open(
        in: directory,
        configuration: failing?.configuration() ?? .default
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

  /// Makes one statement's step fail while switched on, standing in for a pragma SQLite refuses.
  private final class FailingStatement: Sendable {
    private let sql: String
    private let failing = Lock(false)

    init(_ sql: String) {
      self.sql = sql
    }

    var isFailing: Bool {
      get { failing.withLock { $0 } }
      set { failing.withLock { $0 = newValue } }
    }

    func configuration() -> SQLiteConfiguration {
      let base = builtInTestLibrary
      var configuration = SQLiteConfiguration.default
      configuration.library = base
      configuration.readerCount = 1
      configuration.library.statements.execution.step = { [self] statement in
        if isFailing, let text = base.statements.inspection.sql(statement),
          String(cString: text) == sql
        {
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
