#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Test
  func openLockMakesASecondAcquisitionWaitForTheFirst() async throws {
    try await withTemporaryDirectory("lock") { directory in
      let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: "open-lock")
      let order = Lock([String]())

      let holder = LockHolder { whileHeld in
        try OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: databaseIdentifier,
          directoryPath: directory.path,
          configuration: .default
        ) {
          whileHeld()
          order.withLock { $0.append("first") }
        }
      }

      let didAcquireSecond = Lock(false)
      // Waits as long as it takes, not the default five seconds, which a loaded machine can spend
      // before the holder lets go.
      var patient = SQLiteConfiguration.default
      patient.busyTimeout = .maximum
      Thread.detachNewThread { [patient] in
        try? OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: databaseIdentifier,
          directoryPath: directory.path,
          configuration: patient
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
  }

  @Test
  func openLockDoesNotBlockDifferentDatabases() throws {
    let held = try HeldOpenLock()
    defer { held.release() }

    let didAcquire = try OrbitDatabaseOpenLock.withLock(
      databaseIdentifier: OrbitDatabaseIdentifier(rawValue: "two"),
      directoryPath: held.directory.path,
      configuration: .default
    ) { true }
    #expect(didAcquire)
  }

  @Test(arguments: [Duration.zero, .milliseconds(200)])
  func openLockGivesUpWithBusyOnceTheBusyTimeoutRunsOut(_ busyTimeout: Duration) async throws {
    let held = try HeldOpenLock()
    defer { held.release() }
    var configuration = SQLiteConfiguration.default
    configuration.busyTimeout = .limit(busyTimeout)

    let (error, elapsed) = try await held.take(configuration: configuration)

    #expect(error?.code == .busy)
    #expect(elapsed >= busyTimeout)
  }

  @Test
  func openLockWaitsByTheBusyHandlerRatherThanTheTimeout() async throws {
    let held = try HeldOpenLock()
    defer { held.release() }
    let attempts = TestRecorder<Int>()
    var configuration = SQLiteConfiguration.default
    // Would give up at once, were the handler not asked instead.
    configuration.busyTimeout = .limit(.zero)
    configuration.busyHandler = { attempt in
      attempts.append(attempt)
      Thread.sleep(forTimeInterval: 0.005)
      return attempt < 3
    }

    let (error, _) = try await held.take(configuration: configuration)

    #expect(error?.code == .busy)
    #expect(attempts.values == [1, 2, 3])
  }

  /// A coordination directory in which another thread holds the open lock of the database `one`.
  private final class HeldOpenLock {
    let directory: URL
    private let holder: LockHolder

    init() throws {
      let directory = try makeShortTemporaryDirectory("lock")
      self.directory = directory
      self.holder = LockHolder { whileHeld in
        try OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: OrbitDatabaseIdentifier(rawValue: "one"),
          directoryPath: directory.path,
          configuration: .default,
          whileHeld
        )
      }
    }

    /// Takes the lock of `one` too, waiting at most five seconds for the try to end.
    func take(
      configuration: SQLiteConfiguration
    ) async throws -> (error: SQLiteError?, elapsed: Duration) {
      let directory = self.directory
      return try await timeSQLiteError {
        try OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: OrbitDatabaseIdentifier(rawValue: "one"),
          directoryPath: directory.path,
          configuration: configuration
        ) {}
      }
    }

    /// Lets go of the lock, and removes the directory.
    func release() {
      self.holder.release()
      try? FileManager.default.removeItem(at: self.directory)
    }
  }

  /// Runs `body` on a thread of its own, as ``withDeadline(_:_:)`` does, and times it.
  ///
  /// - Parameter onStart: Called once the time taken is being counted.
  /// - Returns: The ``SQLiteError`` `body` threw, if it did, and how long it took.
  /// - Throws: ``TestTimeout`` if `body` is still running at `deadline`, or whatever else it
  ///   threw.
  private func timeSQLiteError(
    deadline: Duration = .seconds(5),
    onStart: @escaping @Sendable () -> Void = {},
    _ body: @escaping @Sendable () throws -> Void
  ) async throws -> (error: SQLiteError?, elapsed: Duration) {
    try await withDeadline(deadline) {
      let start = ContinuousClock.now
      onStart()
      do {
        try body()
        return (nil, .now - start)
      } catch let error as SQLiteError {
        return (error, .now - start)
      }
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
      try await peer.waitUntilReady()
      peer.suspend(holder)

      let (error, elapsed) = try await peer.database.open(busyTimeout: .milliseconds(200))

      #expect(error?.code == .busy)
      #expect(elapsed >= .milliseconds(200))
      // Still the frozen holder's.
      #expect(FileManager.default.fileExists(atPath: peer.database.lockFile.path))
    }

    @Test(arguments: [OpenLockHolderFate.resumed, .killed])
    func aPoolOpensOnceAFrozenOpenerIsResumedOrKilledWithinItsBusyTimeout(
      _ fate: OpenLockHolderFate
    ) async throws {
      let peer = try OpenLockPeer("thawed")
      defer { peer.cleanup() }
      let holder = try peer.spawnHolder()
      try await peer.waitUntilReady()
      peer.suspend(holder)

      let isWaiting = Lock(false)
      let database = peer.database
      async let opening = database.open(busyTimeout: .seconds(30), deadline: .seconds(20)) {
        isWaiting.withLock { $0 = true }
      }
      try await waitUntil { isWaiting.withLock { $0 } }
      try await Task.sleep(for: .milliseconds(300))
      switch fate {
      case .resumed:
        try peer.stop()
        peer.resume(holder)
        try await peer.waitForSuccessfulExit(holder)
      case .killed:
        peer.kill(holder)
        try await peer.waitForExit(holder)
      }
      let (error, elapsed) = try await opening

      #expect(error == nil)
      #expect(elapsed >= .milliseconds(300))
      #expect(elapsed < .seconds(15))
      #expect(!FileManager.default.fileExists(atPath: peer.database.lockFile.path))
    }

    @Test
    func aPoolOpensAtOnceAfterAnOpenerIsKilledAndRemovesTheLockFileItLeft() async throws {
      let peer = try OpenLockPeer("killed")
      defer { peer.cleanup() }
      let holder = try peer.spawnHolder()
      try await peer.waitUntilReady()
      peer.kill(holder)
      try await peer.waitForExit(holder)
      // Killed before it could unlink it.
      #expect(FileManager.default.fileExists(atPath: peer.database.lockFile.path))

      // The kernel let go of the lock with the process, so there is nothing to wait for.
      let (error, _) = try await peer.database.open(busyTimeout: .zero)

      #expect(error == nil)
      #expect(!FileManager.default.fileExists(atPath: peer.database.lockFile.path))
    }

    @Test
    func aPoolGivesUpWithBusyAtOnceWhenItsBusyHandlerDoes() async throws {
      let peer = try OpenLockPeer("handler")
      defer { peer.cleanup() }
      let holder = try peer.spawnHolder()
      try await peer.waitUntilReady()
      peer.suspend(holder)
      let attempts = TestRecorder<Int>()
      var configuration = SQLiteConfiguration.default
      // The handler is asked instead of waiting this out.
      configuration.busyTimeout = .maximum
      configuration.busyHandler = { attempt in
        attempts.append(attempt)
        return false
      }

      let (error, _) = try await peer.database.open(configuration: configuration)

      #expect(error?.code == .busy)
      #expect(attempts.values == [1])
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

  /// A process that holds the open lock of a database another process set up, until told to stop.
  @Test
  func openLockProcessPeer() async {
    await runProcessTestPeer(OpenLockPeer.helper) { peer in
      guard peer.mode == "hold" else { throw peer.unknownMode }
      let database = OpenLockPeer.database(in: peer.directory)
      try OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: .forDatabase(path: OrbitDatabasePath(database.path)),
        directoryPath: database.directory.path,
        configuration: .default
      ) {
        try peer.markReady()
        peer.waitForStopBlocking()
      }
    }
  }

  /// A database, the coordination directory its pools open it through, and the one helper
  /// process a test runs holding its open lock.
  private final class OpenLockPeer: ProcessTestHarness {
    static let helper = "openLockProcessPeer"

    var database: OpenLockDatabase { Self.database(in: self.directory) }

    init(_ name: String) throws {
      try super.init(helper: Self.helper, name: name)
    }

    static func database(in directory: URL) -> OpenLockDatabase {
      OpenLockDatabase(
        path: directory.appending(path: "test.sqlite").path,
        directory: directory.appending(path: "c")
      )
    }

    func spawnHolder() throws -> Process {
      try self.spawn(mode: "hold")
    }
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

    /// Opens a pool on the database with `busyTimeout`, as ``open(configuration:deadline:onStart:)``
    /// does.
    func open(
      busyTimeout: Duration,
      deadline: Duration = .seconds(5),
      onStart: @escaping @Sendable () -> Void = {}
    ) async throws -> (error: SQLiteError?, elapsed: Duration) {
      var configuration = SQLiteConfiguration.default
      configuration.busyTimeout = .limit(busyTimeout)
      return try await self.open(configuration: configuration, deadline: deadline, onStart: onStart)
    }

    /// Opens a pool on the database with `configuration`, and waits at most `deadline` for it, as
    /// ``timeSQLiteError(deadline:onStart:_:)`` does.
    func open(
      configuration: SQLiteConfiguration,
      deadline: Duration = .seconds(5),
      onStart: @escaping @Sendable () -> Void = {}
    ) async throws -> (error: SQLiteError?, elapsed: Duration) {
      try await timeSQLiteError(deadline: deadline, onStart: onStart) {
        _ = try SQLitePool(
          path: OrbitDatabasePath(self.path),
          configuration: configuration,
          coordinationDirectoryPath: self.directory.path
        )
      }
    }
  }
#endif
