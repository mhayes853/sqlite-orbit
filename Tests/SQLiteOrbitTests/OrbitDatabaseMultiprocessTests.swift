#if BuiltInSQLite && (canImport(Darwin) || canImport(Glibc))
  import Foundation
  @testable import SQLiteOrbit
  import StructuredQueries
  import Synchronization
  import Testing

  @Suite(.serialized)
  struct OrbitDatabaseMultiprocessTests {
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
        #expect(FileManager.default.fileExists(atPath: harness.file("opened-\(index)").path))
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

    @Test
    func openingWaitsWhileAnotherProcessIsOpening() async throws {
      let harness = try OrbitDatabaseProcessHarness(name: "open-lock")
      defer { harness.cleanup() }
      let identifier = OrbitDatabaseIdentifier.forDatabase(
        path: OrbitDatabasePath(harness.databasePath)
      )
      let directory = harness.coordination.directory
      let opened = harness.file("opened-0")
      let isHeld = Mutex(false)
      let mayRelease = Mutex(false)

      Thread.detachNewThread {
        try? OrbitDatabaseOpenLock.withLock(databaseIdentifier: identifier, directory: directory) {
          isHeld.withLock { $0 = true }
          while !mayRelease.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
        }
      }
      try await waitUntil { isHeld.withLock { $0 } }
      let opener = try harness.spawn("open", index: 0)
      try await waitForFile(harness.file("ready-0"))
      try harness.start()
      try await Task.sleep(for: .milliseconds(100))

      #expect(!FileManager.default.fileExists(atPath: opened.path))

      mayRelease.withLock { $0 = true }
      try await harness.waitForSuccessfulExit(opener)
      #expect(FileManager.default.fileExists(atPath: opened.path))
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
      let holder = try harness.spawn("hold", index: 0, holdMilliseconds: 800)
      try await waitForFile(harness.file("held-0"))

      var configuration = SQLiteConfiguration.default
      configuration.busyTimeout = .milliseconds(100)
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

    @Test
    func writeIsDeliveredToARealSubscriberInAnotherProcess() async throws {
      // Nothing subscribes through OrbitDatabase itself yet, but the transport it announces
      // through is real, so a peer that subscribes to it directly must still see the commit.
      let harness = try OrbitDatabaseProcessHarness(name: "deliver")
      defer { harness.cleanup() }
      let listener = try harness.spawn("listen", index: 0)
      try await waitForFile(harness.file("ready-0"))

      try await harness.database()
        .write { transaction in
          try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
        }

      try await harness.waitForSuccessfulExit(listener)
      #expect(FileManager.default.fileExists(atPath: harness.file("received-0").path))
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
      let updater = try harness.spawn("reuse-update", index: 0)
      try await harness.waitUntilReady(1)

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
    func openLockReleasesWhenItsHolderProcessIsKilled() async throws {
      // flock is tied to the file descriptor, which the kernel closes when a process dies, so a
      // holder that crashes must not leave the lock stuck for whoever opens next.
      let harness = try OrbitDatabaseProcessHarness(name: "open-lock-crash")
      defer { harness.cleanup() }
      let holder = try harness.spawn("hold-open-lock", index: 0)
      try await waitForFile(harness.file("ready-0"))

      harness.kill(holder)
      try await harness.waitForExit(holder)

      let databasePath = harness.databasePath
      let coordination = harness.coordination
      let didOpen = Mutex(false)
      Thread.detachNewThread {
        _ = try? OrbitDatabase(path: OrbitDatabasePath(databasePath), coordination: coordination)
        didOpen.withLock { $0 = true }
      }
      try await waitUntil(timeout: .seconds(5)) { didOpen.withLock { $0 } }
      #expect(FileManager.default.fileExists(atPath: harness.databasePath))
    }
  }

  @Test
  func orbitDatabasePeer() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let mode = environment[OrbitDatabaseProcessEnvironment.mode] else { return }
    func value(_ key: String) throws -> String { try #require(environment[key]) }
    let coordination = UnixDatagramIPCTransport.Configuration(
      directory: URL(fileURLWithPath: try value(OrbitDatabaseProcessEnvironment.directory)),
      backPressure: .fail
    )
    let path = try value(OrbitDatabaseProcessEnvironment.database)
    let ready = URL(fileURLWithPath: try value(OrbitDatabaseProcessEnvironment.ready))
    let start = URL(fileURLWithPath: try value(OrbitDatabaseProcessEnvironment.start))

    switch mode {
    case "open":
      try touch(ready)
      try await waitForFile(start)
      _ = try OrbitDatabase(path: OrbitDatabasePath(path), coordination: coordination)
      try touch(URL(fileURLWithPath: try value(OrbitDatabaseProcessEnvironment.opened)))

    case "write":
      let database = try OrbitDatabase(path: OrbitDatabasePath(path), coordination: coordination)
      let writerID = try #require(Int(try value(OrbitDatabaseProcessEnvironment.writerID)))
      let writeCount = try #require(Int(try value(OrbitDatabaseProcessEnvironment.writeCount)))
      try touch(ready)
      try await waitForFile(start)
      for sequence in 0..<writeCount {
        try await database.write { transaction in
          try transaction.execute(
            #sql(
              """
              INSERT INTO writes (writer_id, sequence)
              VALUES (\(bind: writerID), \(bind: sequence))
              """,
              as: Void.self
            )
          )
        }
      }

    case "hold":
      let database = try OrbitDatabase(path: OrbitDatabasePath(path), coordination: coordination)
      let held = URL(fileURLWithPath: try value(OrbitDatabaseProcessEnvironment.held))
      let milliseconds = try #require(
        Int(try value(OrbitDatabaseProcessEnvironment.holdMilliseconds))
      )
      try touch(ready)
      try await database.write { transaction in
        try transaction.execute(
          #sql("INSERT INTO writes (writer_id) VALUES (1)", as: Void.self)
        )
        try touch(held)
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
      }

    case "listen":
      // `shared` caches transports weakly, so the transport itself, not just the subscription,
      // must be kept alive for as long as the subscription should stay registered.
      let identifier = OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath(path))
      let transport = try UnixDatagramIPCTransport.shared(configuration: coordination)
      let receivedCount = Mutex(0)
      let subscription = try transport.subscribe(to: identifier) { _ in
        receivedCount.withLock { $0 += 1 }
      }
      try touch(ready)
      try await waitUntil(timeout: .seconds(10)) { receivedCount.withLock { $0 } >= 1 }
      try touch(URL(fileURLWithPath: try value(OrbitDatabaseProcessEnvironment.received)))
      _ = subscription

    case "reuse-update":
      let driver = try SQLiteQueue(path: OrbitDatabasePath(path))
      let observer = ChangedRegionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)
      let update = OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(
        #sql("UPDATE items SET quantity = quantity + 1 WHERE id = 1", as: Void.self)
      )
      try await driver.write { transaction in
        var cursor = try transaction.rowCursor(update, cached: true)
        while try cursor.next() != nil {}
      }
      try touch(ready)
      try await waitForFile(start)
      try await driver.write { transaction in
        var cursor = try transaction.rowCursor(update, cached: true)
        while try cursor.next() != nil {}
      }

      guard
        observer.regions == [
          OrbitDatabaseRegion(column: "quantity", in: "items"),
          OrbitDatabaseRegion(columns: ["quantity", "doubled"], in: "items")
        ]
      else {
        processTestExit(1)
      }
      _ = subscription

    case "hold-open-lock":
      let identifier = OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath(path))
      try OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: identifier,
        directory: coordination.directory
      ) {
        try touch(ready)
        Thread.sleep(forTimeInterval: 30)
      }

    default:
      Issue.record("unknown peer mode \(mode)")
      processTestExit(1)
    }
    processTestExit(0)
  }

  private final class OrbitDatabaseProcessHarness {
    private let harness: ProcessTestHarness

    let databasePath: String

    var coordination: UnixDatagramIPCTransport.Configuration {
      UnixDatagramIPCTransport.Configuration(
        directory: self.harness.directory,
        backPressure: .fail
      )
    }

    init(name: String) throws {
      self.harness = try ProcessTestHarness(
        helper: "orbitDatabasePeer",
        environmentPrefix: OrbitDatabaseProcessEnvironment.prefix,
        name: name
      )
      self.databasePath = self.harness.file("test.sqlite").path
    }

    func file(_ name: String) -> URL { self.harness.file(name) }

    func database(
      configuration: SQLiteConfiguration = .default
    ) throws -> OrbitDatabase<SQLitePool> {
      try OrbitDatabase(
        path: OrbitDatabasePath(self.databasePath),
        configuration: configuration,
        coordination: self.coordination
      )
    }

    func spawn(
      _ mode: String,
      index: Int,
      writeCount: Int = 0,
      holdMilliseconds: Int = 0
    ) throws -> Process {
      try self.harness.spawn([
        "MODE": mode,
        "DIRECTORY": self.harness.directory.path,
        "DATABASE": self.databasePath,
        "READY": self.harness.file("ready-\(index)").path,
        "START": self.harness.file("start").path,
        "HELD": self.harness.file("held-\(index)").path,
        "OPENED": self.harness.file("opened-\(index)").path,
        "RECEIVED": self.harness.file("received-\(index)").path,
        "WRITER_ID": String(index),
        "WRITE_COUNT": String(writeCount),
        "HOLD_MS": String(holdMilliseconds)
      ])
    }

    func waitUntilReady(_ count: Int) async throws {
      for index in 0..<count { try await waitForFile(self.harness.file("ready-\(index)")) }
    }

    func start() throws { try touch(self.harness.file("start")) }

    func waitForSuccessfulExit(_ process: Process) async throws {
      try await self.harness.waitForSuccessfulExit(process)
    }

    func waitForExit(_ process: Process) async throws {
      try await self.harness.waitForExit(process)
    }

    func kill(_ process: Process) { self.harness.kill(process) }

    func cleanup() { self.harness.cleanup() }
  }

  private enum OrbitDatabaseProcessEnvironment {
    static let prefix = "SQLITE_ORBIT_DATABASE_HELPER_"
    static let mode = prefix + "MODE"
    static let directory = prefix + "DIRECTORY"
    static let database = prefix + "DATABASE"
    static let ready = prefix + "READY"
    static let start = prefix + "START"
    static let held = prefix + "HELD"
    static let opened = prefix + "OPENED"
    static let received = prefix + "RECEIVED"
    static let writerID = prefix + "WRITER_ID"
    static let writeCount = prefix + "WRITE_COUNT"
    static let holdMilliseconds = prefix + "HOLD_MS"
  }

  private final class ChangedRegionObserver: OrbitDatabaseTransactionObserver, Sendable {
    private let recordedRegions = Mutex([OrbitDatabaseRegion]())

    var regions: [OrbitDatabaseRegion] { recordedRegions.withLock { $0 } }

    func databaseDidChange(in region: OrbitDatabaseRegion) {
      recordedRegions.withLock { $0.append(region) }
    }
  }
#endif
