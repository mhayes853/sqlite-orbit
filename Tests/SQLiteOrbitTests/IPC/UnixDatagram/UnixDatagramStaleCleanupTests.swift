#if canImport(Darwin) || os(Linux) || os(Android)
  import Dispatch
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct UnixDatagramStaleCleanupTests {
    @Test
    func removesADeadEndpointsSocketAndMarkersAndKeepsLiveOnesAndItsOwn() throws {
      let coordination = try StaleCleanupDirectory()
      defer { coordination.remove() }
      let live = try coordination.bindSocket("live")
      try coordination.leaveDeadSocket("dead")
      // The sweeping endpoint's own files are left alone even when it looks dead.
      try coordination.leaveDeadSocket("self")
      for key in ["k1", "k2", "k3"] {
        try coordination.writeMarker("dead", in: key)
      }
      try coordination.writeMarker("live", in: "k1")
      try coordination.writeMarker("self", in: "k2")

      let summary = UnixDatagramStaleCleanup.sweep(
        directory: coordination.directory,
        keeping: "self"
      )

      #expect(summary?.socketCount == 1)
      #expect(summary?.markerCount == 3)
      #expect(summary?.databaseDirectoryCount == 1)
      #expect(try coordination.sockets() == ["live.sock", "self.sock"])
      #expect(try coordination.markers() == ["k1": ["live"], "k2": ["self"]])
      withExtendedLifetime(live) {}
    }

    @Test
    func removesMarkersWithoutASocketAndTemporaryMarkersOfDeadEndpoints() throws {
      let coordination = try StaleCleanupDirectory()
      defer { coordination.remove() }
      let live = try coordination.bindSocket("live")
      try coordination.leaveDeadSocket("dead")
      try coordination.writeMarker("ghost", in: "k1")
      try coordination.writeMarker(".dead.tmp", in: "k1")
      try coordination.writeMarker(".ghost.tmp", in: "k1")
      try coordination.writeMarker(".live.tmp", in: "k1")
      // Nothing an endpoint writes, so nobody's to remove.
      try coordination.writeMarker(".stray", in: "k1")

      let summary = UnixDatagramStaleCleanup.sweep(
        directory: coordination.directory,
        keeping: "self"
      )

      #expect(summary?.markerCount == 3)
      #expect(try coordination.markers() == ["k1": [".live.tmp", ".stray"]])
      withExtendedLifetime(live) {}
    }

    @Test
    func removesADeadHiddenSocketOnlyOnceItIsOlderThanTheGracePeriod() throws {
      let coordination = try StaleCleanupDirectory()
      defer { coordination.remove() }
      // Bound under the hidden name, as a bind that died before renaming its socket leaves it.
      try coordination.leaveDeadSocket(".dead")
      let live = try coordination.bindSocket(".live")
      try coordination.age(".dead.sock")
      try coordination.age(".live.sock")
      try coordination.leaveDeadSocket(".young")

      let summary = UnixDatagramStaleCleanup.sweep(
        directory: coordination.directory,
        keeping: "self"
      )

      #expect(summary?.temporarySocketCount == 1)
      #expect(summary?.socketCount == 0)
      #expect(try coordination.sockets() == [".live.sock", ".young.sock"])

      let immediate = UnixDatagramStaleCleanup.sweep(
        directory: coordination.directory,
        keeping: "self",
        temporarySocketGracePeriod: .zero
      )

      #expect(immediate?.temporarySocketCount == 1)
      #expect(try coordination.sockets() == [".live.sock"])
      withExtendedLifetime(live) {}
    }

    @Test
    func removesEmptyDatabaseDirectoriesOnly() throws {
      let coordination = try StaleCleanupDirectory()
      defer { coordination.remove() }
      let live = try coordination.bindSocket("live")
      try coordination.writeMarker("live", in: "full")
      try FileManager.default.createDirectory(
        at: coordination.databases.appending(path: "empty"),
        withIntermediateDirectories: true
      )

      let summary = UnixDatagramStaleCleanup.sweep(
        directory: coordination.directory,
        keeping: "self"
      )

      #expect(summary?.databaseDirectoryCount == 1)
      #expect(try coordination.markers() == ["full": ["live"]])
      withExtendedLifetime(live) {}
    }

    @Test
    func removesLockFilesNobodyHolds() throws {
      let coordination = try StaleCleanupDirectory()
      defer { coordination.remove() }
      let locks = coordination.directory.appending(path: "open-locks")
      try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
      try Data().write(to: locks.appending(path: "abandoned.lock"))
      let held = OrbitDatabaseIdentifier(rawValue: "held")

      let (summary, remaining) = try OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: held,
        directory: coordination.directory
      ) {
        let summary = UnixDatagramStaleCleanup.sweep(
          directory: coordination.directory,
          keeping: "self"
        )
        return (summary, try FileManager.default.contentsOfDirectory(atPath: locks.path))
      }

      #expect(summary?.lockCount == 1)
      #expect(remaining == ["\(held.coordinationKey).lock"])
    }

    @Test
    func skipsTheSweepWhileAnotherIsUnderWay() throws {
      let coordination = try StaleCleanupDirectory()
      defer { coordination.remove() }
      try coordination.leaveDeadSocket("dead")
      try coordination.writeMarker("dead", in: "k1")
      let lock = coordination.directory.appending(path: "v1/cleanup-stale.lock").path

      let skipped = try UnixFileLock.withExclusiveLock(atPath: lock) {
        UnixDatagramStaleCleanup.sweep(directory: coordination.directory, keeping: "self")
      }

      #expect(skipped == nil)
      #expect(try coordination.sockets() == ["dead.sock"])
      #expect(try coordination.markers() == ["k1": ["dead"]])

      let summary = UnixDatagramStaleCleanup.sweep(
        directory: coordination.directory,
        keeping: "self"
      )

      #expect(summary?.socketCount == 1)
      #expect(summary?.markerCount == 1)
      #expect(try coordination.sockets().isEmpty)
      #expect(try coordination.markers().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: lock))
    }

    @Test
    func concurrentSweepsAndStartingEndpointsLeaveEveryLiveFileAndNoDeadOne() throws {
      let coordination = try StaleCleanupDirectory()
      defer { coordination.remove() }
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
          let summary = UnixDatagramStaleCleanup.sweep(
            directory: coordination.directory,
            keeping: "self"
          )
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
      let harness = try ProcessTestHarness(
        helper: "staleCleanupProcessPeer",
        environmentPrefix: StaleCleanupEnvironment.prefix,
        name: "stale"
      )
      defer { harness.cleanup() }
      let coordination = StaleCleanupDirectory(harness.file("c"))
      let ready = harness.file("ready")
      let process = try harness.spawn([
        "MODE": "crash",
        "DIRECTORY": coordination.directory.path,
        "READY": ready.path
      ])
      try await waitForFile(ready)
      harness.kill(process)
      try await harness.waitForExit(process)
      let locks = coordination.directory.appending(path: "open-locks").path
      #expect(try coordination.sockets().count == 1)
      #expect(try coordination.markers().values.map(\.count) == [1])
      #expect(try FileManager.default.contentsOfDirectory(atPath: locks).count == 1)

      let summary = UnixDatagramStaleCleanup.sweep(
        directory: coordination.directory,
        keeping: "self"
      )

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

  /// A process that advertises a database and holds its open lock until it is killed.
  @Test
  func staleCleanupProcessPeer() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment[StaleCleanupEnvironment.mode] == "crash" else { return }
    let directory = URL(
      fileURLWithPath: try #require(environment[StaleCleanupEnvironment.directory])
    )
    let ready = URL(fileURLWithPath: try #require(environment[StaleCleanupEnvironment.ready]))
    let database = OrbitDatabaseIdentifier(rawValue: "crashed")
    let transport = try UnixDatagramIPCTransport(configuration: .init(directory: directory))
    let subscription = try transport.subscribe(to: database, region: .fullDatabase) { _ in }
    try OrbitDatabaseOpenLock.withLock(databaseIdentifier: database, directory: directory) {
      try touch(ready)
      Thread.sleep(forTimeInterval: 30)
    }
    _ = subscription
    processTestExit(0)
  }

  private enum StaleCleanupEnvironment {
    static let prefix = "SQLITE_ORBIT_STALE_HELPER_"
    static let mode = prefix + "MODE"
    static let directory = prefix + "DIRECTORY"
    static let ready = prefix + "READY"
  }

  /// A socket bound for as long as this is kept.
  private final class LiveSocket: Sendable {
    let socket: UnixDatagramSocket

    init(_ socket: consuming UnixDatagramSocket) {
      self.socket = socket
    }
  }

  /// A coordination directory laid out as endpoints lay it out, and filled by hand.
  private struct StaleCleanupDirectory: Sendable {
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
