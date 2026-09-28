#if canImport(Darwin) || os(Linux) || os(Android)
  import Dispatch
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  final class UnixDatagramStaleCleanupTests: Sendable {
    let coordination: StaleCleanupDirectory

    init() throws {
      self.coordination = try StaleCleanupDirectory()
    }

    deinit {
      self.coordination.remove()
    }

    @Test
    func removesADeadEndpointsSocketAndMarkersAndKeepsLiveOnesAndItsOwn() throws {
      let live = try coordination.bindSocket("live")
      try coordination.leaveDeadSocket("dead")
      // The sweeping endpoint's own files are left alone even when it looks dead.
      try coordination.leaveDeadSocket("self")
      for key in ["k1", "k2", "k3"] {
        try coordination.writeMarker("dead", in: key)
      }
      try coordination.writeMarker("live", in: "k1")
      try coordination.writeMarker("self", in: "k2")

      let summary = coordination.sweep()

      #expect(summary?.socketCount == 1)
      #expect(summary?.markerCount == 3)
      #expect(summary?.databaseDirectoryCount == 1)
      #expect(try coordination.sockets() == ["live.sock", "self.sock"])
      #expect(try coordination.markers() == ["k1": ["live"], "k2": ["self"]])
      withExtendedLifetime(live) {}
    }

    @Test
    func removesMarkersWithoutASocketAndTemporaryMarkersOfDeadEndpoints() throws {
      let live = try coordination.bindSocket("live")
      try coordination.leaveDeadSocket("dead")
      try coordination.writeMarker("ghost", in: "k1")
      try coordination.writeMarker(".dead.tmp", in: "k1")
      try coordination.writeMarker(".ghost.tmp", in: "k1")
      try coordination.writeMarker(".live.tmp", in: "k1")
      // Nothing an endpoint writes, so nobody's to remove.
      try coordination.writeMarker(".stray", in: "k1")

      let summary = coordination.sweep()

      #expect(summary?.markerCount == 3)
      #expect(try coordination.markers() == ["k1": [".live.tmp", ".stray"]])
      withExtendedLifetime(live) {}
    }

    @Test
    func removesADeadHiddenSocketOnlyOnceItIsOlderThanTheGracePeriod() throws {
      // Bound under the hidden name, as a bind that died before renaming its socket leaves it.
      try coordination.leaveDeadSocket(".dead")
      let live = try coordination.bindSocket(".live")
      try coordination.age(".dead.sock")
      try coordination.age(".live.sock")
      try coordination.leaveDeadSocket(".young")

      let summary = coordination.sweep()

      #expect(summary?.temporarySocketCount == 1)
      #expect(summary?.socketCount == 0)
      #expect(try coordination.sockets() == [".live.sock", ".young.sock"])

      let immediate = coordination.sweep(temporarySocketGracePeriod: .zero)

      #expect(immediate?.temporarySocketCount == 1)
      #expect(try coordination.sockets() == [".live.sock"])
      withExtendedLifetime(live) {}
    }

    @Test
    func removesEmptyDatabaseDirectoriesOnly() throws {
      let live = try coordination.bindSocket("live")
      try coordination.writeMarker("live", in: "full")
      try FileManager.default.createDirectory(
        at: coordination.databases.appending(path: "empty"),
        withIntermediateDirectories: true
      )

      let summary = coordination.sweep()

      #expect(summary?.databaseDirectoryCount == 1)
      #expect(try coordination.markers() == ["full": ["live"]])
      withExtendedLifetime(live) {}
    }

    @Test
    func removesLockFilesNobodyHolds() throws {
      let locks = coordination.directory.appending(path: "open-locks")
      try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
      try Data().write(to: locks.appending(path: "abandoned.lock"))
      let held = OrbitDatabaseIdentifier(rawValue: "held")

      let (summary, remaining) = try OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: held,
        directory: coordination.directory,
        configuration: .default
      ) {
        let summary = coordination.sweep()
        return (summary, try FileManager.default.contentsOfDirectory(atPath: locks.path))
      }

      #expect(summary?.lockCount == 1)
      #expect(remaining == ["\(held.coordinationKey).lock"])
    }

    @Test
    func skipsTheSweepWhileAnotherIsUnderWay() throws {
      try coordination.leaveDeadSocket("dead")
      try coordination.writeMarker("dead", in: "k1")
      let lock = coordination.directory.appending(path: "v1/cleanup-stale.lock").path

      let skipped = try #require(
        try UnixFileLock.withExclusiveLockIfAvailable(atPath: lock) { coordination.sweep() }
      )

      #expect(skipped == nil)
      #expect(try coordination.sockets() == ["dead.sock"])
      #expect(try coordination.markers() == ["k1": ["dead"]])

      let summary = coordination.sweep()

      #expect(summary?.socketCount == 1)
      #expect(summary?.markerCount == 1)
      #expect(try coordination.sockets().isEmpty)
      #expect(try coordination.markers().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: lock))
    }

    @Test
    func aSweepThatStallsLeavesTheFilesOfAnEndpointThatCameBackMeanwhile() throws {
      // Dead as the sweep starts, its socket's file gone, as a live endpoint's is once macOS's
      // cleaner of temporary files has removed it, and back, bound at the same path, by the time
      // the sweep resumes after its first removal.
      let keys = ["k1", "k2", "k3"]
      for key in keys {
        try coordination.writeMarker("back", in: key)
      }
      try coordination.writeMarker(".back.tmp", in: "k1")
      var back: LiveSocket?
      var removedCount = 0

      let summary = coordination.sweep { _ in
        removedCount += 1
        guard back == nil else { return }
        back = try? coordination.bindSocket("back")
      }

      #expect(back != nil)
      #expect(removedCount == 1)
      #expect(summary?.markerCount == 1)
      #expect(try coordination.markers().values.reduce(0) { $0 + $1.count } == keys.count)
      #expect(try coordination.sockets() == ["back.sock"])
      withExtendedLifetime(back) {}
    }

    @Test
    func concurrentSweepsAndStartingEndpointsLeaveEveryLiveFileAndNoDeadOne() throws {
      let deadCount = 20
      let keys = (0..<5).map { "k\($0)" }
      for index in 0..<deadCount {
        try coordination.leaveDeadSocket("dead\(index)")
        for key in keys {
          try coordination.writeMarker("dead\(index)", in: key)
        }
      }
      let summaries = Lock([UnixDatagramStaleCleanup.Summary]())
      let started = Lock([LiveSocket]())
      let failures = Lock(0)

      // Half the threads sweep, and the other half start endpoints the way one does: socket
      // first, markers after.
      DispatchQueue.concurrentPerform(iterations: 16) { index in
        if index.isMultiple(of: 2) {
          let summary = coordination.sweep()
          if let summary { summaries.withLock { $0.append(summary) } }
        } else {
          do {
            let socket = try coordination.bindSocket("live\(index)")
            started.withLock { $0.append(socket) }
            for key in keys {
              try coordination.writeMarker("live\(index)", in: key)
            }
          } catch {
            failures.withLock { $0 += 1 }
          }
        }
      }

      let liveNames = (0..<16).filter { !$0.isMultiple(of: 2) }.map { "live\($0)" }.sorted()
      let completed = summaries.withLock { $0 }
      #expect(failures.withLock { $0 } == 0)
      #expect(!completed.isEmpty)
      // Each file is removed by one sweep only, however many ran.
      #expect(completed.reduce(0) { $0 + $1.socketCount } == deadCount)
      #expect(completed.reduce(0) { $0 + $1.markerCount } == deadCount * keys.count)
      #expect(try coordination.sockets() == liveNames.map { "\($0).sock" })
      #expect(
        try coordination.markers() == Dictionary(uniqueKeysWithValues: keys.map { ($0, liveNames) })
      )
      withExtendedLifetime(started) {}
    }

    @Test
    func removesEverythingOfAKilledProcess() async throws {
      let peer = try StaleCleanupPeer("stale")
      defer { peer.cleanup() }
      let coordination = peer.coordination
      let process = try peer.spawn("advertise-and-hang")
      try await peer.waitUntilReady()
      peer.kill(process)
      try await peer.waitForExit(process)
      let locks = coordination.directory.appending(path: "open-locks").path
      #expect(try coordination.sockets().count == 1)
      #expect(try coordination.markers().values.map(\.count) == [1])
      #expect(try FileManager.default.contentsOfDirectory(atPath: locks).count == 1)

      let summary = coordination.sweep()

      #expect(
        summary
          == UnixDatagramStaleCleanup.Summary(
            socketCount: 1,
            markerCount: 1,
            databaseDirectoryCount: 1,
            lockCount: 1
          )
      )
      #expect(try coordination.sockets().isEmpty)
      #expect(try coordination.markers().isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: locks).isEmpty)
    }
  }

  /// A socket bound for as long as this is kept.
  final class LiveSocket: Sendable {
    let socket: UnixDatagramSocket

    init(_ socket: consuming UnixDatagramSocket) {
      self.socket = socket
    }
  }

  /// A coordination directory laid out as endpoints lay it out, and filled by hand.
  struct StaleCleanupDirectory: Sendable {
    let directory: URL

    var socketsDirectory: URL {
      self.directory.appending(path: "v1/s", directoryHint: .isDirectory)
    }
    var databases: URL { self.directory.appending(path: "v1/d", directoryHint: .isDirectory) }

    init() throws {
      try self.init(makeShortTemporaryDirectory("stale"))
    }

    init(_ directory: URL) {
      self.directory = directory
      for directory in [self.socketsDirectory, self.databases] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
    }

    func remove() { try? FileManager.default.removeItem(at: self.directory) }

    /// The lock a sweep holds while it runs.
    var sweepLock: URL { self.directory.appending(path: "v1/cleanup-stale.lock") }

    /// Sweeps as an endpoint named `self` would, calling `didRemove` after each file of an
    /// endpoint's it removes.
    func sweep(
      temporarySocketGracePeriod: Duration = UnixDatagramStaleCleanup
        .defaultTemporarySocketGracePeriod,
      didRemove: (_ path: String) -> Void = { _ in }
    ) -> UnixDatagramStaleCleanup.Summary? {
      UnixDatagramStaleCleanup.sweep(
        directory: self.directory,
        keeping: "self",
        temporarySocketGracePeriod: temporarySocketGracePeriod,
        didRemove: didRemove
      )
    }

    /// Binds a socket at `v1/s/<name>.sock`, which stays bound while the result is kept.
    func bindSocket(_ name: String) throws -> LiveSocket {
      LiveSocket(
        try UnixDatagramSocket.bind(
          path: self.socketsDirectory.appending(path: "\(name).sock").path,
          receiveBufferByteCount: 4096
        )
      )
    }

    /// Leaves a socket's file at `v1/s/<name>.sock` that nothing is bound to, as a process that
    /// died leaves it.
    func leaveDeadSocket(_ name: String) throws {
      _ = try self.bindSocket(name)
      let path = self.socketsDirectory.appending(path: "\(name).sock").path
      // A process another test spawns at the same moment holds a copy of every descriptor until it
      // execs, so the socket can outlive its closing here by a little.
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while UnixDatagramSocket.probe(path) == .alive, ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.001)
      }
    }

    /// Writes a file named `name` in the directory of the database `key`, creating the directory
    /// again if a sweep removes it in between, as an endpoint advertising does.
    func writeMarker(_ name: String, in key: String) throws {
      let directory = self.databases.appending(path: key, directoryHint: .isDirectory)
      for attempt in 1...3 {
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try Data([0]).write(to: directory.appending(path: name))
          return
        } catch CocoaError.fileNoSuchFile where attempt < 3 {
          continue
        }
      }
    }

    /// Makes the file `name` in `v1/s/` look two minutes old.
    func age(_ name: String) throws {
      try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(-120)],
        ofItemAtPath: self.socketsDirectory.appending(path: name).path
      )
    }

    /// What is in `v1/s/`, sorted.
    func sockets() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: self.socketsDirectory.path).sorted()
    }

    /// What is in each database's directory, sorted, by coordination key.
    func markers() throws -> [String: [String]] {
      var markers: [String: [String]] = [:]
      for key in try FileManager.default.contentsOfDirectory(atPath: self.databases.path) {
        markers[key] = try FileManager.default
          .contentsOfDirectory(atPath: self.databases.appending(path: key).path)
          .sorted()
      }
      return markers
    }
  }
#endif
