#if canImport(Darwin) || canImport(Glibc)
  import Foundation
  import SQLiteOrbit
  import Synchronization
  import Testing

  @Suite(.serialized)
  struct OrbitIPCMultiprocessTests {
    @Test(arguments: [1, 2, 8, 32])
    func publisherFansOutToSubscriberProcesses(subscriberCount: Int) async throws {
      let harness = try IPCProcessHarness(database: "fan-out")
      defer { harness.cleanup() }
      let listeners = try (0..<subscriberCount)
        .map {
          try harness.spawn("listen", index: $0, expected: 1)
        }
      try await harness.waitUntilReady(subscriberCount)

      try await harness.transport(.fail).send(harness.message)

      for (index, listener) in listeners.enumerated() {
        try await harness.waitForSuccessfulExit(listener)
        #expect(try harness.result(index) == 1)
      }
    }

    @Test(arguments: [2, 4, 8])
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

      try await harness.transport(.fail).send(harness.message)

      #expect(try harness.registrationCount() == 0)
    }

    @Test
    func backPressureFailsOrSuspendsWithoutDroppingSilently() async throws {
      let harness = try IPCProcessHarness(database: "back-pressure")
      defer { harness.cleanup() }
      let listener = try harness.spawn("idle")
      try await harness.waitUntilReady(1)
      harness.suspend(listener)

      #expect(
        try await reachesBackPressure(
          harness.transport(.fail, receiveBufferByteCount: 65_535),
          message: harness.message
        )
      )

      let transport = try harness.transport(
        .suspend(upTo: .seconds(2)),
        receiveBufferByteCount: 65_535
      )
      let message = harness.message
      let send = Task { try await transport.send(message) }
      try await Task.sleep(for: .milliseconds(20))
      harness.resume(listener)
      try await send.value
      try harness.stop()
      try await harness.waitForSuccessfulExit(listener)
    }

    @Test
    func suspendedSendTimesOutWhenAReceiverDoesNotDrain() async throws {
      let harness = try IPCProcessHarness(database: "back-pressure-timeout")
      defer { harness.cleanup() }
      let listener = try harness.spawn("idle")
      try await harness.waitUntilReady(1)
      harness.suspend(listener)

      #expect(
        try await reachesBackPressure(
          harness.transport(.suspend(upTo: .milliseconds(20))),
          message: harness.message
        )
      )

      harness.kill(listener)
      try await harness.waitForExit(listener)
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
    let transport = try UnixDatagramIPCTransport(
      configuration: .init(
        directory: directory,
        backPressure: .suspend(upTo: .seconds(5))
      )
    )
    let received = Mutex(0)
    let subscription = try transport.subscribe(to: database) { _ in
      received.withLock { $0 += 1 }
    }
    try touch(ready)

    if mode == "subscribe-and-send" {
      try await waitForFile(directory.appending(path: "start"))
      try await transport.send(.transactionDidCommit(.init(databaseIdentifier: database)))
    }
    if mode == "idle" {
      try await waitForFile(directory.appending(path: "stop"), timeout: .seconds(30))
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
      .transactionDidCommit(.init(databaseIdentifier: self.database))
    }

    init(database: String) throws {
      self.harness = try ProcessTestHarness(
        helper: "ipcProcessPeer",
        environmentPrefix: IPCProcessEnvironment.prefix,
        name: database
      )
      self.database = OrbitDatabaseIdentifier(rawValue: database)
    }

    func transport(
      _ backPressure: UnixDatagramIPCTransport.BackPressurePolicy,
      receiveBufferByteCount: Int = 256 * 1024
    ) throws -> UnixDatagramIPCTransport {
      try UnixDatagramIPCTransport(
        configuration: .init(
          directory: self.directory,
          backPressure: backPressure,
          receiveBufferByteCount: receiveBufferByteCount
        )
      )
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

    /// The number of peer registrations the coordination directory currently advertises.
    func registrationCount() throws -> Int {
      let root = self.harness.file("v1/d")
      guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
      return try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .reduce(0) { $0 + (try FileManager.default.contentsOfDirectory(atPath: $1.path).count) }
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

  private func reachesBackPressure(
    _ transport: UnixDatagramIPCTransport,
    message: OrbitIPCMessage
  ) async throws -> Bool {
    for _ in 0..<10_000 {
      do { try await transport.send(message) } catch is OrbitIPCPartialDeliveryError {
        return true
      }
    }
    return false
  }
#endif
