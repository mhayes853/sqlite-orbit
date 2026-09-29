#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  @testable import SQLiteOrbit
  import Testing

  @Suite(.serialized)
  struct UnixDatagramIPCMultiprocessTests {
    @Test(arguments: [1, 8, 32])
    func publisherFansOutToSubscriberProcesses(subscriberCount: Int) async throws {
      let harness = try IPCProcessHarness(database: "fan-out")
      defer { harness.cleanup() }
      let listeners = try (0..<subscriberCount)
        .map {
          try harness.spawn("listen", index: $0, expected: 1)
        }
      try await harness.waitUntilReady(subscriberCount)

      try await harness.transport().send(harness.message)

      for (index, listener) in listeners.enumerated() {
        try await harness.waitForSuccessfulExit(listener)
        #expect(try harness.result(index) == 1)
      }
    }

    @Test
    func databaseRegionRoundTripsBetweenProcesses() async throws {
      let harness = try IPCProcessHarness(database: "region-round-trip")
      defer { harness.cleanup() }
      let listener = try harness.spawn("listen-region", expected: 1)
      try await harness.waitUntilReady(1)
      let region = OrbitDatabaseRegion.fullDatabase.subtracting(
        OrbitDatabaseRegion(column: "title", in: "items")
      )

      try await harness.transport()
        .send(
          .transactionDidCommit(.init(databaseIdentifier: harness.database, region: region))
        )

      try await harness.waitForSuccessfulExit(listener)
      #expect(try harness.result(0) == 1)
    }

    @Test(arguments: [2, 8])
    func subscribedProcessesBroadcastToEveryOtherProcess(processCount: Int) async throws {
      let harness = try IPCProcessHarness(database: "all-to-all")
      defer { harness.cleanup() }
      let processes = try (0..<processCount)
        .map {
          try harness.spawn("subscribe-and-send", index: $0, expected: processCount - 1)
        }
      try await harness.waitUntilReady(processCount)

      try harness.start()

      for (index, process) in processes.enumerated() {
        try await harness.waitForSuccessfulExit(process)
        #expect(try harness.result(index) == processCount - 1)
      }
    }

    @Test
    func crashedSubscriberRegistrationIsRemovedByTheNextPublisher() async throws {
      let harness = try IPCProcessHarness(database: "stale")
      defer { harness.cleanup() }
      let listener = try harness.spawn("idle")
      try await harness.waitUntilReady(1)
      harness.kill(listener)
      try await harness.waitForExit(listener)
      #expect(try harness.registrationCount() == 1)
      #expect(try harness.socketCount() == 1)

      try await harness.transport().send(harness.message)

      #expect(try harness.registrationCount() == 0)
      #expect(try harness.socketCount() == 0)
    }

    @Test
    func sendsToAStoppedProcessNeitherWaitNorFail() async throws {
      let harness = try IPCProcessHarness(database: "stopped")
      defer { harness.cleanup() }
      let listener = try harness.spawn("idle")
      try await harness.waitUntilReady(1)
      harness.suspend(listener)
      let transport = try harness.transport()

      #expect(try await reachesAFullQueue(transport, message: harness.message))
      for _ in 0..<1_000 {
        try await transport.send(harness.message)
      }
      #expect(transport.owedRegions.count == 1)

      harness.resume(listener)
      try await waitUntil { transport.owedRegions.isEmpty }
      try harness.stop()
      try await harness.waitForSuccessfulExit(listener)
    }

    @Test
    func aStoppedProcessHearsAboutEveryRegionWrittenOnceItResumes() async throws {
      // Far more commits than the stopped process's queue holds, each to a column of its own. Most
      // are merged into what it is owed, so it hears about far fewer commits than were sent, whose
      // regions still cover every column written.
      let harness = try IPCProcessHarness(database: "owed")
      defer { harness.cleanup() }
      let columnCount = 4_000
      let listener = try harness.spawn("listen-columns", expected: columnCount)
      try await harness.waitUntilReady(1)
      harness.suspend(listener)

      let transport = try harness.transport()
      for index in 0..<columnCount {
        try await transport.send(
          columnCommit(harness.database, index)
        )
      }
      #expect(transport.owedRegions.count == 1)
      harness.resume(listener)

      try await harness.waitForSuccessfulExit(listener)
      #expect(try harness.result(0) < columnCount)
    }

    @Test
    func aProcessIsOnlySentCommitsToTheTablesItSubscribedTo() async throws {
      // The listener is stopped while commits to a table it does not read are sent, so had any
      // been sent to it, its queue would have filled and the sender would owe it.
      let harness = try IPCProcessHarness(database: "table-filter")
      defer { harness.cleanup() }
      let listener = try harness.spawn("listen-table-a", expected: 1)
      try await harness.waitUntilReady(1)
      harness.suspend(listener)
      let transport = try harness.transport()

      for _ in 0..<2_000 {
        try await transport.send(
          .transactionDidCommit(
            .init(databaseIdentifier: harness.database, region: OrbitDatabaseRegion(table: "b"))
          )
        )
      }
      #expect(transport.owedRegions.isEmpty)
      harness.resume(listener)
      try await transport.send(
        .transactionDidCommit(
          .init(databaseIdentifier: harness.database, region: OrbitDatabaseRegion(table: "a"))
        )
      )

      try await harness.waitForSuccessfulExit(listener)
      #expect(try harness.result(0) == 1)
    }

    @Test
    func aProcessThatDiesWhileOwedIsDroppedAndPrunedByTheTransportsThread() async throws {
      let harness = try IPCProcessHarness(database: "owed-dead")
      defer { harness.cleanup() }
      let listener = try harness.spawn("idle")
      try await harness.waitUntilReady(1)
      harness.suspend(listener)
      let transport = try harness.transport()
      #expect(try await reachesAFullQueue(transport, message: harness.message))

      harness.kill(listener)
      try await harness.waitForExit(listener)
      // The transport's thread finds it dead when it next tries it, drops what it was owed, and
      // prunes it without waiting for another send.
      try await waitUntil {
        transport.owedRegions.isEmpty && (try? harness.registrationCount()) == 0
      }
      // Only the transport's own socket is left.
      #expect(try harness.socketCount() == 1)
    }

    @Test
    func aProcessWhoseFilesTheCleanerRemovesPutsThemBackAndKeepsReceiving() async throws {
      // What `UnixDatagramRemovedFilesTests` does to an idle endpoint in this process, done to one
      // in a process of its own, as macOS's cleaner of temporary files would.
      // The listener counts only this commit, and exits once it has also been told, by its
      // repair, that the database may have changed.
      let harness = try IPCProcessHarness(database: "cleaned")
      defer { harness.cleanup() }
      let listener = try harness.spawn("listen-repaired", expected: 1)
      try await harness.waitUntilReady(1)
      let files = try UnixDatagramEndpointFiles(
        advertising: harness.database,
        in: harness.directory
      )

      files.removeAsTheCleanerWould()
      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      try await harness.transport()
        .send(
          .transactionDidCommit(
            .init(databaseIdentifier: harness.database, region: OrbitDatabaseRegion(table: "items"))
          )
        )

      try await harness.waitForSuccessfulExit(listener)
      #expect(try harness.result(0) == 1)
    }
  }

  @Test
  func ipcProcessPeer() async {
    await runProcessTestPeer(IPCProcessHarness.helper) { peer in
      let mode = peer.mode
      let database = OrbitDatabaseIdentifier(
        rawValue: try peer.string(IPCProcessHarness.databaseVariable)
      )
      let expected = try peer.int(IPCProcessHarness.expectedVariable)
      // The smallest receive buffer a transport allows, so a stopped peer fills up after a
      // predictable number of commits. Darwin bounds the queue by bytes, and a default buffer
      // holds thousands of these small datagrams.
      let transport = try UnixDatagramIPCTransport(
        configuration: .init(directory: peer.directory, receiveBufferByteCount: 60 * 1024)
      )
      let received = TestCounter()
      let covered = Lock(OrbitDatabaseRegion.empty)
      let isNotified = Lock(false)
      let region: OrbitDatabaseRegion =
        mode == "listen-table-a" ? OrbitDatabaseRegion(table: "a") : .fullDatabase
      let subscription = try transport.subscribe(to: database, region: region) { message in
        if case .transactionDidCommit(let commit) = message {
          covered.withLock { $0.formUnion(commit.region) }
        }
        if mode == "listen-repaired", message == commit(database) {
          // What a repair tells subscribers, which no peer sends in this mode.
          isNotified.withLock { $0 = true }
          return
        }
        if mode == "listen-region" {
          let expectedRegion = OrbitDatabaseRegion.fullDatabase.subtracting(
            OrbitDatabaseRegion(column: "title", in: "items")
          )
          guard message == commit(database, region: expectedRegion) else { return }
        }
        received.increment()
      }
      try peer.markReady()

      switch mode {
      case "subscribe-and-send":
        try await peer.waitForStart()
        try await transport.send(commit(database))
        try await received.waitForCount(expected, timeout: .seconds(10))
      case "idle":
        try await peer.waitForStop()
      case "listen-columns":
        let columns = OrbitDatabaseRegion(columns: (0..<expected).map { "c\($0)" }, in: "items")
        try await waitUntil(timeout: .seconds(30)) { covered.withLock { $0.contains(columns) } }
      case "listen-repaired":
        try await waitUntil { received.value >= expected && isNotified.withLock { $0 } }
      case "listen", "listen-region", "listen-table-a":
        try await received.waitForCount(expected, timeout: .seconds(10))
      default:
        throw peer.unknownMode
      }

      try peer.writeResult(received.value)
      _ = subscription
    }
  }

  /// A coordination directory, which is the harness's own, and the database its helpers subscribe
  /// to.
  private final class IPCProcessHarness: ProcessTestHarness {
    static let helper = "ipcProcessPeer"
    static let databaseVariable = "DATABASE"
    static let expectedVariable = "EXPECTED_COUNT"

    let database: OrbitDatabaseIdentifier

    var message: OrbitIPCMessage { commit(self.database) }

    init(database: String) throws {
      self.database = OrbitDatabaseIdentifier(rawValue: database)
      try super.init(helper: Self.helper, name: database)
    }

    func transport() throws -> UnixDatagramIPCTransport {
      try ipcTransport(self.directory)
    }

    /// Spawns the helper in `mode`, to wait for `expected` commits where its mode waits for any.
    func spawn(_ mode: String, index: Int = 0, expected: Int = 0) throws -> Process {
      try self.spawn(
        mode: mode,
        index: index,
        [
          Self.databaseVariable: self.database.rawValue,
          Self.expectedVariable: String(expected)
        ]
      )
    }

    func registrationCount() throws -> Int {
      let root = self.file("v1/d")
      guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
      return try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .reduce(0) { $0 + (try FileManager.default.contentsOfDirectory(atPath: $1.path).count) }
    }

    func socketCount() throws -> Int {
      let directory = self.file("v1/s")
      guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
      return try FileManager.default.contentsOfDirectory(atPath: directory.path).count
    }
  }

  /// Sends `message` until a peer has no room for it, and is owed its region instead.
  func reachesAFullQueue(
    _ transport: UnixDatagramIPCTransport,
    message: OrbitIPCMessage
  ) async throws -> Bool {
    for _ in 0..<10_000 {
      try await transport.send(message)
      if !transport.owedRegions.isEmpty { return true }
    }
    return false
  }

#endif
