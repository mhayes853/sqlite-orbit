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
      let peer = try StaleCleanupPeer("killed")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      try coordination.leaveDeadSocket("dead")
      try coordination.writeMarker("dead", in: "k1")
      let holder = try peer.spawn("hold")
      try await peer.waitUntilReady()

      peer.kill(holder)
      try await peer.waitForExit(holder)
      // Killed before it could unlink it.
      #expect(FileManager.default.fileExists(atPath: coordination.sweepLock.path))

      let summary = try await withDeadline { coordination.sweep() }

      #expect(summary?.socketCount == 1)
      #expect(summary?.markerCount == 1)
      #expect(try coordination.sockets().isEmpty)
      #expect(try coordination.markers().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: coordination.sweepLock.path))
    }

    @Test
    func aSweepKilledPartwayLeavesTheRestToTheNextAndTheLiveFilesAlone() async throws {
      let peer = try StaleCleanupPeer("partway")
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
      peer.kill(sweeper)
      try await peer.waitForExit(sweeper)
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
      let peer = try StaleCleanupPeer("frozen")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      try coordination.leaveDeadSocket("dead")
      try coordination.writeMarker("dead", in: "k1")
      let holder = try peer.spawn("hold")
      try await peer.waitUntilReady()
      peer.suspend(holder)

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

      peer.kill(holder)
      try await peer.waitForExit(holder)
      let summary = try await withDeadline { coordination.sweep() }

      #expect(summary?.socketCount == 1)
      #expect(summary?.markerCount == 1)
      #expect(try coordination.sockets().count == 2)
      #expect(!FileManager.default.fileExists(atPath: coordination.sweepLock.path))
      _ = subscription
    }

    @Test
    func aFrozenHolderOfTheSweepsLockThatResumesFinishesAndLetsTheNextSweepRun() async throws {
      let peer = try StaleCleanupPeer("resumed")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      try coordination.leaveDeadSocket("dead")
      let holder = try peer.spawn("hold")
      try await peer.waitUntilReady()
      peer.suspend(holder)
      let skipped = try await withDeadline(.seconds(5)) { coordination.sweep() }
      #expect(skipped == nil)

      try peer.stop()
      peer.resume(holder)
      try await peer.waitForSuccessfulExit(holder)
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
      let peer = try StaleCleanupPeer("stopped")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      let keys = ["k0", "k1", "k2"]
      for key in keys {
        try coordination.writeMarker("back", in: key)
      }
      let sweeper = try peer.spawn("sweep-and-wait")
      try await peer.waitUntilReady()
      peer.suspend(sweeper)

      let back = try coordination.bindSocket("back")
      try peer.stop()
      peer.resume(sweeper)
      try await peer.waitForSuccessfulExit(sweeper)

      #expect(try peer.result() == 1)
      #expect(try coordination.markers().values.reduce(0) { $0 + $1.count } == keys.count - 1)
      #expect(try coordination.sockets() == ["back.sock"])
      withExtendedLifetime(back) {}
    }
  }

  /// A process that holds the sweep's lock, sweeps, or holds what an endpoint holds, in a
  /// coordination directory another process set up, and stalls where its mode says.
  ///
  /// - `hold`: holds the lock until told to stop.
  /// - `sweep-and-hang`: sweeps, and stalls for good after its first removal.
  /// - `sweep-and-wait`: sweeps, stalls after its first removal until told to stop, and reports
  ///   how many markers it removed.
  /// - `advertise-and-hang`: advertises a database, and holds its open lock until it is killed.
  @Test
  func staleCleanupProcessPeer() async {
    await runProcessTestPeer(StaleCleanupPeer.helper) { peer in
      let coordination = StaleCleanupPeer.coordination(in: peer.directory)

      switch peer.mode {
      case "hold":
        _ = try UnixFileLock.withExclusiveLockIfAvailable(atPath: coordination.sweepLock.path) {
          try peer.markReady()
          peer.waitForStopBlocking()
        }
      case "sweep-and-hang", "sweep-and-wait":
        let hangs = peer.mode == "sweep-and-hang"
        var hasStalled = false
        let summary = coordination.sweep { _ in
          guard !hasStalled else { return }
          hasStalled = true
          try? peer.markReady()
          if hangs {
            Thread.sleep(forTimeInterval: 30)
            processTestExit(1)
          }
          peer.waitForStopBlocking()
        }
        try peer.writeResult(summary?.markerCount ?? -1)
      case "advertise-and-hang":
        let database = OrbitDatabaseIdentifier(rawValue: "crashed")
        let directory = coordination.directory
        let transport = try ipcTransport(directory)
        let subscription = try transport.subscribe(to: database, region: .fullDatabase) { _ in }
        try OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: database,
          directory: directory,
          configuration: .default
        ) {
          try peer.markReady()
          Thread.sleep(forTimeInterval: 30)
        }
        _ = subscription
      default:
        throw peer.unknownMode
      }
    }
  }

  /// A coordination directory, and the one helper process a test runs in it.
  final class StaleCleanupPeer: ProcessTestHarness {
    static let helper = "staleCleanupProcessPeer"

    lazy var coordination = Self.coordination(in: self.directory)

    init(_ name: String) throws {
      try super.init(helper: Self.helper, name: name)
    }

    static func coordination(in directory: URL) -> StaleCleanupDirectory {
      StaleCleanupDirectory(directory.appending(path: "c"))
    }

    func spawn(_ mode: String) throws -> Process {
      try self.spawn(mode: mode)
    }
  }
#endif
