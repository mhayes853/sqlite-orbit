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
  func ipcProcessPeer() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let mode = environment[IPCProcessEnvironment.mode] else { return }
    func value(_ key: String) throws -> String { try #require(environment[key]) }
    let directory = URL(fileURLWithPath: try value(IPCProcessEnvironment.directory))
    let database = OrbitDatabaseIdentifier(rawValue: try value(IPCProcessEnvironment.database))
    let ready = URL(fileURLWithPath: try value(IPCProcessEnvironment.ready))
    let result = URL(fileURLWithPath: try value(IPCProcessEnvironment.result))
    let expected = try #require(Int(try value(IPCProcessEnvironment.expected)))
    // The smallest receive buffer a transport allows, so a stopped peer fills up after a
    // predictable number of commits. Darwin bounds the queue by bytes, and a default buffer holds
    // thousands of these small datagrams.
    let transport = try UnixDatagramIPCTransport(
      configuration: .init(directory: directory, receiveBufferByteCount: 60 * 1024)
    )
    let received = Lock(0)
    let covered = Lock(OrbitDatabaseRegion.empty)
    let isNotified = Lock(false)
    let region: OrbitDatabaseRegion =
      mode == "listen-table-a" ? OrbitDatabaseRegion(table: "a") : .fullDatabase
    let subscription = try transport.subscribe(to: database, region: region) { message in
      if case .transactionDidCommit(let commit) = message {
        covered.withLock { $0.formUnion(commit.region) }
      }
      if mode == "listen-repaired",
        message == .transactionDidCommit(.init(databaseIdentifier: database, region: .fullDatabase))
      {
        // What a repair tells subscribers, which no peer sends in this mode.
        isNotified.withLock { $0 = true }
        return
      }
      if mode == "listen-region" {
        let expectedRegion = OrbitDatabaseRegion.fullDatabase.subtracting(
          OrbitDatabaseRegion(column: "title", in: "items")
        )
        guard
          message
            == .transactionDidCommit(
              .init(databaseIdentifier: database, region: expectedRegion)
            )
        else { return }
      }
      received.withLock { $0 += 1 }
    }
    try touch(ready)

    if mode == "subscribe-and-send" {
      try await waitForFile(directory.appending(path: "start"))
      try await transport.send(
        .transactionDidCommit(.init(databaseIdentifier: database, region: .fullDatabase))
      )
    }
    if mode == "idle" {
      try await waitForFile(directory.appending(path: "stop"), timeout: .seconds(30))
    } else if mode == "listen-columns" {
      let columns = OrbitDatabaseRegion(columns: (0..<expected).map { "c\($0)" }, in: "items")
      try await waitUntil(timeout: .seconds(30)) { covered.withLock { $0.contains(columns) } }
    } else if mode == "listen-repaired" {
      try await waitUntil { received.withLock { $0 } >= expected && isNotified.withLock { $0 } }
    } else {
      try await waitUntil { received.withLock { $0 } >= expected }
    }

    try Data(String(received.withLock { $0 }).utf8).write(to: result, options: .atomic)
    _ = subscription
    processTestExit(0)
  }

  private final class IPCProcessHarness {
    private let harness: ProcessTestHarness
    let database: OrbitDatabaseIdentifier

    var directory: URL { self.harness.directory }

    var message: OrbitIPCMessage {
      .transactionDidCommit(.init(databaseIdentifier: self.database, region: .fullDatabase))
    }

    init(database: String) throws {
      self.harness = try ProcessTestHarness(
        helper: "ipcProcessPeer",
        environmentPrefix: IPCProcessEnvironment.prefix,
        name: database
      )
      self.database = OrbitDatabaseIdentifier(rawValue: database)
    }

    func transport() throws -> UnixDatagramIPCTransport {
      try UnixDatagramIPCTransport(configuration: .init(directory: self.directory))
    }

    func spawn(_ mode: String, index: Int = 0, expected: Int = 0) throws -> Process {
      try self.harness.spawn([
        "MODE": mode,
        "DIRECTORY": self.directory.path,
        "DATABASE": self.database.rawValue,
        "READY": self.harness.file("ready-\(index)").path,
        "RESULT": self.harness.file("result-\(index)").path,
        "EXPECTED_COUNT": String(expected)
      ])
    }

    func waitUntilReady(_ count: Int) async throws {
      for index in 0..<count { try await waitForFile(self.harness.file("ready-\(index)")) }
    }

    func start() throws { try touch(self.harness.file("start")) }
    func stop() throws { try touch(self.harness.file("stop")) }

    func result(_ index: Int) throws -> Int {
      try #require(Int(String(contentsOf: self.harness.file("result-\(index)"), encoding: .utf8)))
    }

    func registrationCount() throws -> Int {
      let root = self.harness.file("v1/d")
      guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
      return try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .reduce(0) { $0 + (try FileManager.default.contentsOfDirectory(atPath: $1.path).count) }
    }

    func socketCount() throws -> Int {
      let directory = self.harness.file("v1/s")
      guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
      return try FileManager.default.contentsOfDirectory(atPath: directory.path).count
    }

    func waitForSuccessfulExit(_ process: Process) async throws {
      try await self.harness.waitForSuccessfulExit(process)
    }

    func waitForExit(_ process: Process) async throws {
      try await self.harness.waitForExit(process)
    }

    func suspend(_ process: Process) { self.harness.suspend(process) }
    func resume(_ process: Process) { self.harness.resume(process) }
    func kill(_ process: Process) { self.harness.kill(process) }
    func cleanup() { self.harness.cleanup() }
  }

  private enum IPCProcessEnvironment {
    static let prefix = "SQLITE_ORBIT_IPC_HELPER_"
    static let mode = prefix + "MODE"
    static let directory = prefix + "DIRECTORY"
    static let database = prefix + "DATABASE"
    static let ready = prefix + "READY"
    static let result = prefix + "RESULT"
    static let expected = prefix + "EXPECTED_COUNT"
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
