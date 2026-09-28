#if canImport(Darwin) || os(Linux) || os(Android)
  import Dispatch
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  private final class OpenLockHolder: Sendable {
    private let acquired = DispatchSemaphore(value: 0)
    private let mayRelease = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    init(
      _ databaseIdentifier: OrbitDatabaseIdentifier,
      in directory: URL,
      onRelease: @escaping @Sendable () -> Void = {}
    ) {
      Thread.detachNewThread {
        try? OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: databaseIdentifier,
          directory: directory,
          configuration: .default
        ) {
          self.acquired.signal()
          self.mayRelease.wait()
          onRelease()
        }
        self.released.signal()
      }
      acquired.wait()
    }

    func release() {
      mayRelease.signal()
      released.wait()
    }
  }

  @Test
  func openLockMakesASecondAcquisitionWaitForTheFirst() async throws {
    let directory = try makeShortTemporaryDirectory("lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: "open-lock")
    let order = Lock([String]())

    let holder = OpenLockHolder(databaseIdentifier, in: directory) {
      order.withLock { $0.append("first") }
    }

    let didAcquireSecond = Lock(false)
    Thread.detachNewThread {
      try? OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: databaseIdentifier,
        directory: directory,
        configuration: .default
      ) {
        order.withLock { $0.append("second") }
        didAcquireSecond.withLock { $0 = true }
      }
    }

    // The second acquisition cannot be observed to *not* happen without giving it a chance to.
    try await Task.sleep(for: .milliseconds(50))
    #expect(order.withLock { $0 }.isEmpty)

    holder.release()
    try await waitUntil { didAcquireSecond.withLock { $0 } }
    #expect(order.withLock { $0 } == ["first", "second"])
  }

  @Test
  func openLockDoesNotBlockDifferentDatabases() throws {
    let directory = try makeShortTemporaryDirectory("lock")
    defer { try? FileManager.default.removeItem(at: directory) }

    let holder = OpenLockHolder(OrbitDatabaseIdentifier(rawValue: "one"), in: directory)
    defer { holder.release() }

    let didAcquire = try OrbitDatabaseOpenLock.withLock(
      databaseIdentifier: OrbitDatabaseIdentifier(rawValue: "two"),
      directory: directory,
      configuration: .default
    ) { true }
    #expect(didAcquire)
  }
  @Test
  func openLockGivesUpWithBusyOnceTheBusyTimeoutRunsOut() async throws {
    let directory = try makeShortTemporaryDirectory("lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: "open-lock")
    let holder = OpenLockHolder(databaseIdentifier, in: directory)
    defer { holder.release() }
    var configuration = SQLiteConfiguration.default
    configuration.busyTimeout = .limit(.milliseconds(200))

    let (error, elapsed) = try await withDeadline(.seconds(5)) { [configuration] in
      let clock = ContinuousClock()
      let start = clock.now
      let error = openLockError(databaseIdentifier, in: directory, configuration: configuration)
      return (error, start.duration(to: clock.now))
    }

    #expect(error?.code == .busy)
    #expect(elapsed >= .milliseconds(200))
  }

  @Test
  func openLockGivesUpAtOnceWithoutABusyTimeout() async throws {
    let directory = try makeShortTemporaryDirectory("lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: "open-lock")
    let holder = OpenLockHolder(databaseIdentifier, in: directory)
    defer { holder.release() }
    var configuration = SQLiteConfiguration.default
    configuration.busyTimeout = .limit(.zero)

    let error = try await withDeadline(.seconds(5)) { [configuration] in
      openLockError(databaseIdentifier, in: directory, configuration: configuration)
    }

    #expect(error?.code == .busy)
  }

  @Test
  func openLockWaitsByTheBusyHandlerRatherThanTheTimeout() async throws {
    let directory = try makeShortTemporaryDirectory("lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: "open-lock")
    let holder = OpenLockHolder(databaseIdentifier, in: directory)
    defer { holder.release() }
    let attempts = Lock([Int]())
    var configuration = SQLiteConfiguration.default
    // Would give up at once, were the handler not asked instead.
    configuration.busyTimeout = .limit(.zero)
    configuration.busyHandler = { attempt in
      attempts.withLock { $0.append(attempt) }
      Thread.sleep(forTimeInterval: 0.005)
      return attempt < 3
    }

    let error = try await withDeadline(.seconds(5)) { [configuration] in
      openLockError(databaseIdentifier, in: directory, configuration: configuration)
    }

    #expect(error?.code == .busy)
    #expect(attempts.withLock { $0 } == [1, 2, 3])
  }

  /// Takes the open lock, and returns the ``SQLiteError`` that taking it threw, if it did.
  private func openLockError(
    _ databaseIdentifier: OrbitDatabaseIdentifier,
    in directory: URL,
    configuration: SQLiteConfiguration
  ) -> SQLiteError? {
    do {
      try OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: databaseIdentifier,
        directory: directory,
        configuration: configuration
      ) {}
      return nil
    } catch {
      return error as? SQLiteError
    }
  }
  /// What becomes of a pool opening a database while another process that is opening it, and so
  /// holds its open lock, freezes or dies.
  ///
  /// The pool waits for it only as long as its busy timeout or busy handler says, as SQLite waits
  /// for its own locks. Every open runs with a deadline, so a change that makes it wait for good
  /// fails these tests rather than hanging them, and the helper is killed as each test ends,
  /// stopped or not.
  @Suite(.serialized)
  struct OrbitDatabaseOpenLockProcessTests {
    @Test
    func aPoolGivesUpWithBusyOnAFrozenOpenerOnceItsBusyTimeoutRunsOut() async throws {
      let peer = try OpenLockPeer("frozen")
      defer { peer.cleanup() }
      let holder = try peer.spawnHolder()
      try await peer.waitUntilHolding()
      peer.harness.suspend(holder)

      let (error, elapsed) = try await peer.database.open(busyTimeout: .milliseconds(200))

      #expect(error?.code == .busy)
      #expect(elapsed >= .milliseconds(200))
      // Still the frozen holder's.
      #expect(FileManager.default.fileExists(atPath: peer.lockFile.path))
    }

    @Test(arguments: [OpenLockHolderFate.resumed, .killed])
    func aPoolOpensOnceAFrozenOpenerIsResumedOrKilledWithinItsBusyTimeout(
      _ fate: OpenLockHolderFate
    ) async throws {
      let peer = try OpenLockPeer("thawed")
      defer { peer.cleanup() }
      let holder = try peer.spawnHolder()
      try await peer.waitUntilHolding()
      peer.harness.suspend(holder)

      let isWaiting = Lock(false)
      let database = peer.database
      async let opening = database.open(busyTimeout: .seconds(30), deadline: .seconds(20)) {
        isWaiting.withLock { $0 = true }
      }
      try await waitUntil { isWaiting.withLock { $0 } }
      try await Task.sleep(for: .milliseconds(300))
      switch fate {
      case .resumed:
        try peer.go()
        peer.harness.resume(holder)
        try await peer.harness.waitForSuccessfulExit(holder)
      case .killed:
        peer.harness.kill(holder)
        try await peer.harness.waitForExit(holder)
      }
      let (error, elapsed) = try await opening

      #expect(error == nil)
      #expect(elapsed >= .milliseconds(300))
      #expect(elapsed < .seconds(15))
      #expect(!FileManager.default.fileExists(atPath: peer.lockFile.path))
    }

    @Test
    func aPoolOpensAtOnceAfterAnOpenerIsKilledAndRemovesTheLockFileItLeft() async throws {
      let peer = try OpenLockPeer("killed")
      defer { peer.cleanup() }
      let holder = try peer.spawnHolder()
      try await peer.waitUntilHolding()
      peer.harness.kill(holder)
      try await peer.harness.waitForExit(holder)
      // Killed before it could unlink it.
      #expect(FileManager.default.fileExists(atPath: peer.lockFile.path))

      // The kernel let go of the lock with the process, so there is nothing to wait for.
      let (error, _) = try await peer.database.open(busyTimeout: .zero)

      #expect(error == nil)
      #expect(!FileManager.default.fileExists(atPath: peer.lockFile.path))
    }

    @Test
    func aPoolGivesUpWithBusyAtOnceWhenItsBusyHandlerDoes() async throws {
      let peer = try OpenLockPeer("handler")
      defer { peer.cleanup() }
      let holder = try peer.spawnHolder()
      try await peer.waitUntilHolding()
      peer.harness.suspend(holder)
      let attempts = Lock([Int]())
      var configuration = SQLiteConfiguration.default
      // The handler is asked instead of waiting this out.
      configuration.busyTimeout = .maximum
      configuration.busyHandler = { attempt in
        attempts.withLock { $0.append(attempt) }
        return false
      }

      let (error, _) = try await peer.database.open(
        configuration: configuration,
        deadline: .seconds(5)
      )

      #expect(error?.code == .busy)
      #expect(attempts.withLock { $0 } == [1])
    }
  }

  enum OpenLockHolderFate: CustomTestStringConvertible, Sendable {
    case resumed
    case killed

    var testDescription: String {
      switch self {
      case .resumed: "resumed"
      case .killed: "killed"
      }
    }
  }

  /// A process that holds the open lock of a database another process set up, until told to go
  /// on.
  @Test
  func openLockProcessPeer() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment[OpenLockEnvironment.mode] == "hold" else { return }
    func url(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(environment[key])) }
    let database = try url(OpenLockEnvironment.database)
    let ready = try url(OpenLockEnvironment.ready)
    let go = try url(OpenLockEnvironment.go)

    try OrbitDatabaseOpenLock.withLock(
      databaseIdentifier: .forDatabase(path: OrbitDatabasePath(database.path)),
      directory: try url(OpenLockEnvironment.directory),
      configuration: .default
    ) {
      try touch(ready)
      processTestWaitForFile(go)
    }
    processTestExit(0)
  }

  private enum OpenLockEnvironment {
    static let prefix = "SQLITE_ORBIT_OPEN_LOCK_HELPER_"
    static let mode = prefix + "MODE"
    static let directory = prefix + "DIRECTORY"
    static let database = prefix + "DATABASE"
    static let ready = prefix + "READY"
    static let go = prefix + "GO"
  }

  /// A database, the coordination directory its pools open it through, and the one helper
  /// process a test runs holding its open lock.
  private final class OpenLockPeer {
    let harness: ProcessTestHarness
    let database: OpenLockDatabase

    /// The file the helper holds the lock on.
    var lockFile: URL { self.database.lockFile }

    init(_ name: String) throws {
      self.harness = try ProcessTestHarness(
        helper: "openLockProcessPeer",
        environmentPrefix: OpenLockEnvironment.prefix,
        name: name
      )
      self.database = OpenLockDatabase(
        path: self.harness.file("test.sqlite").path,
        directory: self.harness.file("c")
      )
    }

    func spawnHolder() throws -> Process {
      try self.harness.spawn([
        "MODE": "hold",
        "DIRECTORY": self.database.directory.path,
        "DATABASE": self.database.path,
        "READY": self.harness.file("ready").path,
        "GO": self.harness.file("go").path
      ])
    }

    /// Waits for the helper to hold the lock.
    func waitUntilHolding() async throws { try await waitForFile(self.harness.file("ready")) }

    /// Tells the helper to let go of the lock and exit.
    func go() throws { try touch(self.harness.file("go")) }

    /// Kills the helper, stopped or not, and removes the directory.
    func cleanup() { self.harness.cleanup() }
  }

  /// A database and the coordination directory its pools open it through.
  private struct OpenLockDatabase: Sendable {
    let path: String
    let directory: URL

    /// Where ``OrbitDatabaseOpenLock`` keeps the file its lock is on.
    var lockFile: URL {
      let identifier = OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath(self.path))
      return self.directory.appending(path: "open-locks/\(identifier.coordinationKey).lock")
    }

    /// Opens a pool on the database with `busyTimeout`, and waits at most `deadline` for it.
    func open(
      busyTimeout: Duration,
      deadline: Duration = .seconds(5),
      onStart: @escaping @Sendable () -> Void = {}
    ) async throws -> (error: SQLiteError?, elapsed: Duration) {
      var configuration = SQLiteConfiguration.default
      configuration.busyTimeout = .limit(busyTimeout)
      return try await self.open(configuration: configuration, deadline: deadline, onStart: onStart)
    }

    /// Opens a pool on the database with `configuration`, and waits at most `deadline` for it.
    ///
    /// - Parameter onStart: Called once the time taken is being counted.
    /// - Returns: The ``SQLiteError`` the open threw, if it did, and how long it took.
    /// - Throws: ``TestTimeout`` if the open is still under way at `deadline`, or whatever else
    ///   it threw.
    func open(
      configuration: SQLiteConfiguration,
      deadline: Duration,
      onStart: @escaping @Sendable () -> Void = {}
    ) async throws -> (error: SQLiteError?, elapsed: Duration) {
      try await withDeadline(deadline) {
        let clock = ContinuousClock()
        let start = clock.now
        onStart()
        do {
          _ = try SQLitePool(
            path: OrbitDatabasePath(self.path),
            configuration: configuration,
            coordinationDirectory: self.directory
          )
          return (nil, start.duration(to: clock.now))
        } catch let error as SQLiteError {
          return (error, start.duration(to: clock.now))
        }
      }
    }
  }
#endif
