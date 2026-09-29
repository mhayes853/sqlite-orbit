#if BuiltInSQLite && (canImport(Darwin) || os(Linux) || os(Android))
  import Foundation
  @testable import SQLiteOrbit
  import StructuredQueries
  import Testing

  @Suite(.serialized)
  struct OrbitIPCDatabaseMultiprocessTests {
    @Test
    func manyProcessesCanOpenTheSameNewDatabaseAtOnce() async throws {
      let harness = try OrbitDatabaseProcessHarness(name: "open")
      defer { harness.cleanup() }
      let openerCount = 10
      let openers = try (0..<openerCount).map { try harness.spawn("open", index: $0) }
      try await harness.waitUntilReady(openerCount)

      try harness.start()

      for (index, opener) in openers.enumerated() {
        try await harness.waitForSuccessfulExit(opener)
        #expect(harness.isMarked("opened", index: index))
      }
      #expect(FileManager.default.fileExists(atPath: harness.databasePath))
      let database = try harness.database()
      let tableCount = try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM sqlite_master", as: Int.self))
      }
      #expect(tableCount == 0)
      // Moving a new database into WAL needs an exclusive lock of SQLite's own, so a race between
      // openers would leave it in the default journal mode.
      let journalMode = try await database.read { transaction in
        try transaction.fetchAll(#sql("PRAGMA journal_mode", as: String.self))
      }
      #expect(journalMode == ["wal"])
    }

    @Test(arguments: [false, true])
    func openingWaitsWhileAnotherProcessIsOpening(throughSymlink: Bool) async throws {
      let harness = try OrbitDatabaseProcessHarness(name: "open-lock")
      defer { harness.cleanup() }
      let identifier = OrbitDatabaseIdentifier.forDatabase(
        path: OrbitDatabasePath(harness.databasePath)
      )
      let directory = harness.coordination.directory
      let isHeld = Lock(false)
      let mayRelease = Lock(false)

      Thread.detachNewThread {
        try? OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: identifier,
          directory: directory,
          configuration: .default
        ) {
          isHeld.withLock { $0 = true }
          while !mayRelease.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
        }
      }
      try await waitUntil { isHeld.withLock { $0 } }
      defer { mayRelease.withLock { $0 = true } }
      let opener = try harness.spawn(
        "open",
        databasePath: throughSymlink ? harness.symlinkedDatabasePath() : harness.databasePath
      )
      try await harness.waitUntilReady()
      try harness.start()
      try await Task.sleep(for: .milliseconds(100))

      #expect(!harness.isMarked("opened"))

      mayRelease.withLock { $0 = true }
      try await harness.waitForSuccessfulExit(opener)
      #expect(harness.isMarked("opened"))
    }

    @Test
    func contentiousWritesFromManyProcessesAllCommit() async throws {
      let harness = try OrbitDatabaseProcessHarness(name: "write")
      defer { harness.cleanup() }
      let database = try harness.database()
      try await database.write { transaction in
        try transaction.execute(
          #sql(
            """
            CREATE TABLE writes (
              writer_id INTEGER NOT NULL,
              sequence INTEGER NOT NULL
            )
            """,
            as: Void.self
          )
        )
      }
      let writerCount = 8
      let writesPerWriter = 20
      let writers = try (0..<writerCount)
        .map {
          try harness.spawn("write", index: $0, writeCount: writesPerWriter)
        }
      try await harness.waitUntilReady(writerCount)

      try harness.start()

      for writer in writers { try await harness.waitForSuccessfulExit(writer) }
      let count = try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM writes", as: Int.self))
      }
      #expect(count == writerCount * writesPerWriter)
    }

    @Test
    func writeGivesUpWhileAnotherProcessHoldsTheWriteTransaction() async throws {
      let harness = try OrbitDatabaseProcessHarness(name: "busy")
      defer { harness.cleanup() }
      try await harness.database()
        .write { transaction in
          try transaction.execute(
            #sql("CREATE TABLE writes (writer_id INTEGER NOT NULL)", as: Void.self)
          )
        }
      let holder = try harness.spawn("hold", holdMilliseconds: 800)
      try await harness.waitUntilMarked("held")

      var configuration = SQLiteConfiguration.default
      configuration.busyTimeout = .limit(.milliseconds(100))
      let database = try harness.database(configuration: configuration)
      let clock = ContinuousClock()
      let started = clock.now
      let error = await #expect(throws: SQLiteError.self) {
        try await database.write { transaction in
          try transaction.execute(
            #sql("INSERT INTO writes (writer_id) VALUES (9999)", as: Void.self)
          )
        }
      }
      let elapsed = clock.now - started

      #expect(error?.primaryCode == .busy)
      #expect(elapsed < .milliseconds(700))
      try await harness.waitForSuccessfulExit(holder)
    }

    @Test(arguments: [false, true])
    func writeIsDeliveredToARealSubscriberInAnotherProcess(throughSymlink: Bool) async throws {
      // Nothing subscribes through OrbitIPCDatabase itself yet, but the transport it announces
      // through is real, so a peer that subscribes to it directly must still see the commit.
      let harness = try OrbitDatabaseProcessHarness(name: "deliver")
      defer { harness.cleanup() }
      let listener = try harness.spawn(
        "listen",
        databasePath: throughSymlink ? harness.symlinkedDatabasePath() : harness.databasePath
      )
      try await harness.waitUntilReady()

      try await harness.database()
        .write { transaction in
          try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
        }

      try await harness.waitForSuccessfulExit(listener)
      #expect(harness.isMarked("received"))
    }

    @Test
    func schemaCookieRecompilesCachedUpdatesAcrossProcesses() async throws {
      // SQLiteQueue has no IPC transport: SQLite's schema cookie is the only cross-process signal
      // that can make the updater replace its cached statement metadata.
      let harness = try OrbitDatabaseProcessHarness(name: "schema-cookie")
      defer { harness.cleanup() }
      let database = try SQLiteQueue(path: OrbitDatabasePath(harness.databasePath))
      try await database.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE items (
            id INTEGER PRIMARY KEY,
            quantity INTEGER NOT NULL
          );
          INSERT INTO items VALUES (1, 1);
          """
        )
      }
      let updater = try harness.spawn("reuse-update")
      try await harness.waitUntilReady()

      try await database.write { transaction in
        try transaction.execute(
          """
          ALTER TABLE items ADD COLUMN doubled INTEGER
            GENERATED ALWAYS AS (quantity * 2)
          """
        )
      }
      try harness.start()

      try await harness.waitForSuccessfulExit(updater)
    }

    @Test
    func migratingFromManyProcessesAppliesEachMigrationOnce() async throws {
      let harness = try OrbitDatabaseProcessHarness(name: "migrate")
      defer { harness.cleanup() }
      let migratorCount = 4
      let migrators = try (0..<migratorCount).map { try harness.spawn("migrate", index: $0) }
      try await harness.waitUntilReady(migratorCount)

      try harness.start()

      for migrator in migrators { try await harness.waitForSuccessfulExit(migrator) }
      try await expectContendedMigrationsAppliedOnce(in: try harness.database())
    }

    @Test
    func openLockReleasesWhenItsHolderProcessIsKilled() async throws {
      // flock is tied to the file descriptor, which the kernel closes when a process dies, so a
      // holder that crashes must not leave the lock stuck for whoever opens next.
      let harness = try OrbitDatabaseProcessHarness(name: "open-lock-crash")
      defer { harness.cleanup() }
      let holder = try harness.spawn("hold-open-lock")
      try await harness.waitUntilReady()

      harness.kill(holder)
      try await harness.waitForExit(holder)

      let databasePath = harness.databasePath
      let coordination = harness.coordination
      _ = try await withDeadline(.seconds(5)) {
        try OrbitIPCDatabase(path: OrbitDatabasePath(databasePath), coordination: coordination)
      }
      #expect(FileManager.default.fileExists(atPath: harness.databasePath))
    }
  }

  @Test
  func orbitIPCDatabasePeer() async {
    await runProcessTestPeer(OrbitDatabaseProcessHarness.helper) { peer in
      let coordination = UnixDatagramIPCTransport.Configuration(directory: peer.directory)
      let path = OrbitDatabasePath(try peer.string(OrbitDatabaseProcessHarness.databaseVariable))

      switch peer.mode {
      case "open":
        try peer.markReady()
        try await peer.waitForStart()
        // Waits for the test's hold on the open lock as long as it takes, not the default five
        // seconds, which a loaded machine can spend before the test lets go.
        var configuration = SQLiteConfiguration.default
        configuration.busyTimeout = .maximum
        _ = try OrbitIPCDatabase(
          path: path,
          configuration: configuration,
          coordination: coordination
        )
        try peer.mark("opened")

      case "write":
        let database = try OrbitIPCDatabase(path: path, coordination: coordination)
        let writeCount = try peer.int(OrbitDatabaseProcessHarness.writeCountVariable)
        try peer.markReady()
        try await peer.waitForStart()
        for sequence in 0..<writeCount {
          try await database.write { transaction in
            try transaction.execute(
              #sql(
                """
                INSERT INTO writes (writer_id, sequence)
                VALUES (\(bind: peer.index), \(bind: sequence))
                """,
                as: Void.self
              )
            )
          }
        }

      case "migrate":
        let database = try OrbitIPCDatabase(path: path, coordination: coordination)
        try peer.markReady()
        try await peer.waitForStart()
        try await makeContendedMigrator().migrate(database)

      case "hold":
        let database = try OrbitIPCDatabase(path: path, coordination: coordination)
        let milliseconds = try peer.int(OrbitDatabaseProcessHarness.holdMillisecondsVariable)
        try peer.markReady()
        try await database.write { transaction in
          try transaction.execute(
            #sql("INSERT INTO writes (writer_id) VALUES (1)", as: Void.self)
          )
          try peer.mark("held")
          Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
        }

      case "listen":
        // `shared` caches transports weakly, so the transport itself, not just the subscription,
        // must be kept alive for as long as the subscription should stay registered.
        let transport = try UnixDatagramIPCTransport.shared(configuration: coordination)
        let received = TestCounter()
        let subscription = try transport.subscribe(to: .forDatabase(path: path)) { _ in
          received.increment()
        }
        try peer.markReady()
        try await received.waitForCount(1, timeout: .seconds(10))
        try peer.mark("received")
        _ = subscription

      case "reuse-update":
        let driver = try SQLiteQueue(path: path)
        let observer = TransactionEventRecorder()
        let subscription = try driver.subscribe(transactionObserver: observer)
        let update = OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(
          #sql("UPDATE items SET quantity = quantity + 1 WHERE id = 1", as: Void.self)
        )
        try await driver.write { transaction in
          var cursor = try transaction.rowCursor(update, cached: true)
          while try cursor.next() != nil {}
        }
        try peer.markReady()
        try await peer.waitForStart()
        try await driver.write { transaction in
          var cursor = try transaction.rowCursor(update, cached: true)
          while try cursor.next() != nil {}
        }

        try #require(
          observer.changedRegions == [
            OrbitDatabaseRegion(column: "quantity", in: "items"),
            OrbitDatabaseRegion(columns: ["quantity", "doubled"], in: "items")
          ]
        )
        _ = subscription

      case "hold-open-lock":
        try OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: .forDatabase(path: path),
          directory: coordination.directory,
          configuration: .default
        ) {
          try peer.markReady()
          Thread.sleep(forTimeInterval: 30)
        }

      default:
        throw peer.unknownMode
      }
    }
  }

  /// A database, and the coordination directory the processes that open it share, which is the
  /// harness's own.
  private final class OrbitDatabaseProcessHarness: ProcessTestHarness {
    static let helper = "orbitIPCDatabasePeer"
    static let databaseVariable = "DATABASE"
    static let writeCountVariable = "WRITE_COUNT"
    static let holdMillisecondsVariable = "HOLD_MS"

    var databasePath: String { self.file("test.sqlite").path }

    var coordination: UnixDatagramIPCTransport.Configuration {
      UnixDatagramIPCTransport.Configuration(directory: self.directory)
    }

    init(name: String) throws {
      try super.init(helper: Self.helper, name: name)
    }

    func database(
      configuration: SQLiteConfiguration = .default
    ) throws -> OrbitIPCDatabase {
      try OrbitIPCDatabase(
        path: OrbitDatabasePath(self.databasePath),
        configuration: configuration,
        coordination: self.coordination
      )
    }

    func symlinkedDatabasePath() throws -> String {
      let alias = self.file("alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: self.directory)
      return alias.appending(path: "test.sqlite").path
    }

    /// Spawns the helper in `mode`, opening the database at `databasePath`, or else the harness's
    /// own.
    func spawn(
      _ mode: String,
      index: Int = 0,
      databasePath: String? = nil,
      writeCount: Int = 0,
      holdMilliseconds: Int = 0
    ) throws -> Process {
      try self.spawn(
        mode: mode,
        index: index,
        [
          Self.databaseVariable: databasePath ?? self.databasePath,
          Self.writeCountVariable: String(writeCount),
          Self.holdMillisecondsVariable: String(holdMilliseconds)
        ]
      )
    }
  }
#endif
