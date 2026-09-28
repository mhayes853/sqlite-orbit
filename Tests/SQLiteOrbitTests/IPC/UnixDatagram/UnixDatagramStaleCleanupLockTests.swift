#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  /// What becomes of the sweeps, and of the transports starting, when a process that is sweeping,
  /// or holds the sweep's lock, dies or freezes.
  ///
  /// Nothing may ever end up waiting on such a process. Everything that could block runs with a
  /// deadline, so a change that makes it wait fails these tests rather than hanging them, and
  /// every helper is killed as each test ends, stopped or not.
  @Suite(.serialized)
  struct UnixDatagramStaleCleanupLockTests {
    @Test
    func aHolderOfTheSweepsLockThatIsKilledLeavesItToTheNextSweep() async throws {
      let peer = try StaleCleanupLockPeer("killed")
      defer { peer.cleanup() }
      try peer.coordination.leaveDeadSocket("dead")
      try peer.coordination.writeMarker("dead", in: "k1")
      let holder = try peer.spawn("hold")
      try await peer.waitUntilReady()

      peer.harness.kill(holder)
      try await peer.harness.waitForExit(holder)
      // Killed before it could unlink it.
      #expect(FileManager.default.fileExists(atPath: peer.coordination.sweepLock.path))

      let coordination = peer.coordination
      let summary = try await withDeadline { coordination.sweep() }

      #expect(summary?.socketCount == 1)
      #expect(summary?.markerCount == 1)
      #expect(try coordination.sockets().isEmpty)
      #expect(try coordination.markers().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: coordination.sweepLock.path))
    }

    @Test
    func aSweepKilledPartwayLeavesTheRestToTheNextAndTheLiveFilesAlone() async throws {
      let peer = try StaleCleanupLockPeer("partway")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      let keys = ["k0", "k1", "k2"]
      let deadCount = 4
      let live = try coordination.bindSocket("live")
      for key in keys {
        try coordination.writeMarker("live", in: key)
      }
      for index in 0..<deadCount {
        try coordination.leaveDeadSocket("dead\(index)")
        for key in keys {
          try coordination.writeMarker("dead\(index)", in: key)
        }
      }
      try coordination.writeMarker(".dead0.tmp", in: "k0")

      // It stalls for good right after its first removal, which is of a dead socket's file.
      let sweeper = try peer.spawn("sweep-and-hang")
      try await peer.waitUntilReady()
      peer.harness.kill(sweeper)
      try await peer.harness.waitForExit(sweeper)
      #expect(try coordination.sockets().count == deadCount)
      #expect(FileManager.default.fileExists(atPath: coordination.sweepLock.path))

      let summary = try await withDeadline { coordination.sweep() }

      #expect(
        summary
          == UnixDatagramStaleCleanup.Summary(
            socketCount: deadCount - 1,
            markerCount: deadCount * keys.count + 1
          )
      )
      #expect(try coordination.sockets() == ["live.sock"])
      #expect(
        try coordination.markers()
          == Dictionary(uniqueKeysWithValues: keys.map { ($0, ["live"]) })
      )
      #expect(!FileManager.default.fileExists(atPath: coordination.sweepLock.path))
      withExtendedLifetime(live) {}
    }

    @Test
    func aFrozenHolderOfTheSweepsLockHoldsUpNeitherSweepsNorStartingTransports() async throws {
      let peer = try StaleCleanupLockPeer("frozen")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      try coordination.leaveDeadSocket("dead")
      try coordination.writeMarker("dead", in: "k1")
      let holder = try peer.spawn("hold")
      try await peer.waitUntilReady()
      peer.harness.suspend(holder)

      // Skipped rather than waited for.
      let skipped = try await withDeadline(.seconds(5)) { coordination.sweep() }
      #expect(skipped == nil)
      #expect(try coordination.sockets() == ["dead.sock"])

      // Each skips its sweep too, and they work as ever.
      let directory = coordination.directory
      let (receiver, sender) = try await withDeadline {
        (try ipcTransport(directory), try ipcTransport(directory))
      }
      let database = OrbitDatabaseIdentifier(rawValue: "frozen")
      let recorder = IPCMessageRecorder()
      let subscription = try receiver.subscribe(to: database, onMessage: recorder.append)
      try await sender.send(commit(database))
      try await recorder.waitForCount(1)
      #expect(try coordination.sockets().contains("dead.sock"))

      peer.harness.kill(holder)
      try await peer.harness.waitForExit(holder)
      let summary = try await withDeadline { coordination.sweep() }

      #expect(summary?.socketCount == 1)
      #expect(summary?.markerCount == 1)
      #expect(try coordination.sockets().count == 2)
      #expect(!FileManager.default.fileExists(atPath: coordination.sweepLock.path))
      _ = subscription
    }

    @Test
    func aFrozenHolderOfTheSweepsLockThatResumesFinishesAndLetsTheNextSweepRun() async throws {
      let peer = try StaleCleanupLockPeer("resumed")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      try coordination.leaveDeadSocket("dead")
      let holder = try peer.spawn("hold")
      try await peer.waitUntilReady()
      peer.harness.suspend(holder)
      let skipped = try await withDeadline(.seconds(5)) { coordination.sweep() }
      #expect(skipped == nil)

      try peer.go()
      peer.harness.resume(holder)
      try await peer.harness.waitForSuccessfulExit(holder)
      // Let go of, and unlinked, as it always is.
      #expect(!FileManager.default.fileExists(atPath: coordination.sweepLock.path))

      let summary = try await withDeadline { coordination.sweep() }

      #expect(summary?.socketCount == 1)
      #expect(try coordination.sockets().isEmpty)
    }

    @Test
    func aSweepStoppedPartwayLeavesTheFilesOfAnEndpointThatCameBackMeanwhile() async throws {
      // What `UnixDatagramStaleCleanupTests` does to a sweep in this process, done to one in a
      // process of its own that is stopped between its first removal and the rest.
      let peer = try StaleCleanupLockPeer("stopped")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      let keys = ["k0", "k1", "k2"]
      for key in keys {
        try coordination.writeMarker("back", in: key)
      }
      let sweeper = try peer.spawn("sweep-and-wait")
      try await peer.waitUntilReady()
      peer.harness.suspend(sweeper)

      let back = try coordination.bindSocket("back")
      try peer.go()
      peer.harness.resume(sweeper)
      try await peer.harness.waitForSuccessfulExit(sweeper)

      #expect(try peer.result() == 1)
      #expect(try coordination.markers().values.reduce(0) { $0 + $1.count } == keys.count - 1)
      #expect(try coordination.sockets() == ["back.sock"])
      withExtendedLifetime(back) {}
    }
  }

  /// A process that holds the sweep's lock, or sweeps, in a coordination directory another
  /// process set up, and stalls where its mode says.
  ///
  /// - `hold`: holds the lock until told to go on.
  /// - `sweep-and-hang`: sweeps, and stalls for good after its first removal.
  /// - `sweep-and-wait`: sweeps, stalls after its first removal until told to go on, and reports
  ///   how many markers it removed.
  @Test
  func staleCleanupLockProcessPeer() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let mode = environment[StaleCleanupLockEnvironment.mode] else { return }
    func url(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(environment[key])) }
    let coordination = StaleCleanupDirectory(try url(StaleCleanupLockEnvironment.directory))
    let ready = try url(StaleCleanupLockEnvironment.ready)
    let go = try url(StaleCleanupLockEnvironment.go)
    let result = try url(StaleCleanupLockEnvironment.result)

    /// Waits for the test to say go on, and fails if it never does.
    func waitForGo() {
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      while !FileManager.default.fileExists(atPath: go.path) {
        guard ContinuousClock.now < deadline else { processTestExit(1) }
        Thread.sleep(forTimeInterval: 0.002)
      }
    }

    switch mode {
    case "hold":
      try UnixFileLock.withExclusiveLock(atPath: coordination.sweepLock.path) {
        try touch(ready)
        waitForGo()
      }
    case "sweep-and-hang", "sweep-and-wait":
      var hasStalled = false
      let summary = coordination.sweep { _ in
        guard !hasStalled else { return }
        hasStalled = true
        try? touch(ready)
        if mode == "sweep-and-hang" {
          Thread.sleep(forTimeInterval: 30)
          processTestExit(1)
        }
        waitForGo()
      }
      try Data(String(summary?.markerCount ?? -1).utf8).write(to: result, options: .atomic)
    default:
      processTestExit(1)
    }
    processTestExit(0)
  }

  private enum StaleCleanupLockEnvironment {
    static let prefix = "SQLITE_ORBIT_STALE_LOCK_HELPER_"
    static let mode = prefix + "MODE"
    static let directory = prefix + "DIRECTORY"
    static let ready = prefix + "READY"
    static let go = prefix + "GO"
    static let result = prefix + "RESULT"
  }

  /// A coordination directory, and the one helper process a test runs in it.
  private final class StaleCleanupLockPeer {
    let harness: ProcessTestHarness
    let coordination: StaleCleanupDirectory

    init(_ name: String) throws {
      self.harness = try ProcessTestHarness(
        helper: "staleCleanupLockProcessPeer",
        environmentPrefix: StaleCleanupLockEnvironment.prefix,
        name: name
      )
      self.coordination = StaleCleanupDirectory(self.harness.file("c"))
    }

    func spawn(_ mode: String) throws -> Process {
      try self.harness.spawn([
        "MODE": mode,
        "DIRECTORY": self.coordination.directory.path,
        "READY": self.harness.file("ready").path,
        "GO": self.harness.file("go").path,
        "RESULT": self.harness.file("result").path
      ])
    }

    /// Waits for the helper to hold the lock, or to have stalled.
    func waitUntilReady() async throws { try await waitForFile(self.harness.file("ready")) }

    /// Tells a helper that stalled until told to go on.
    func go() throws { try touch(self.harness.file("go")) }

    /// How many markers the helper's sweep removed.
    func result() throws -> Int {
      try #require(Int(String(contentsOf: self.harness.file("result"), encoding: .utf8)))
    }

    /// Kills the helper, stopped or not, and removes the directory.
    func cleanup() { self.harness.cleanup() }
  }

  /// Runs `body` on a thread of its own, and waits at most `timeout` for it to return.
  ///
  /// Whatever might block runs this way, so a change that makes it wait on a stalled process fails
  /// the test with a ``TestTimeout`` rather than hanging it. The thread is left behind if it never
  /// returns.
  private func withDeadline<Value: Sendable>(
    _ timeout: Duration = .seconds(10),
    _ body: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    let outcome = DeadlineOutcome<Value>()
    Thread.detachNewThread {
      let result = Result { try body() }
      outcome.result.withLock { $0 = result }
    }
    try await waitUntil(timeout: timeout) { outcome.result.withLock { $0 != nil } }
    return try outcome.result.withLock { $0! }.get()
  }

  private final class DeadlineOutcome<Value: Sendable>: Sendable {
    let result = Lock<Result<Value, any Error>?>(nil)
  }
#endif
