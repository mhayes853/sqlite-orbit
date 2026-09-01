#if canImport(Darwin) || canImport(Glibc)
  import Foundation
  import SQLiteCross
  import Synchronization
  import Testing

  #if canImport(Darwin)
    import Darwin
  #else
    import Glibc
  #endif

  @Suite(.serialized)
  struct DatabaseIPCMultiprocessTests {
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
    let database = DatabaseIdentifier(rawValue: try value(IPCProcessEnvironment.database))
    let ready = URL(fileURLWithPath: try value(IPCProcessEnvironment.ready))
    let result = URL(fileURLWithPath: try value(IPCProcessEnvironment.result))
    let expected = try #require(Int(try value(IPCProcessEnvironment.expected)))
    let transport = try UnixDatagramDatabaseIPCTransport(
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
    ipcProcessExit(0)
  }

  private final class IPCProcessHarness {
    let directory: URL
    let database: DatabaseIdentifier
    private var processes = [Process]()

    var message: DatabaseIPCMessage {
      .transactionDidCommit(.init(databaseIdentifier: self.database))
    }

    init(database: String) throws {
      self.directory = FileManager.default.temporaryDirectory
        .appending(path: "sqlite-cross-process-tests-\(UUID().uuidString)")
      self.database = DatabaseIdentifier(rawValue: database)
      try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func transport(
      _ backPressure: UnixDatagramDatabaseIPCTransport.BackPressurePolicy,
      receiveBufferByteCount: Int = 256 * 1024
    ) throws -> UnixDatagramDatabaseIPCTransport {
      try UnixDatagramDatabaseIPCTransport(
        configuration: .init(
          directory: self.directory,
          backPressure: backPressure,
          receiveBufferByteCount: receiveBufferByteCount
        )
      )
    }

    func spawn(_ mode: String, index: Int = 0, expected: Int = 0) throws -> Process {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = [
        "--testing-library", "swift-testing", "--filter", "ipcProcessPeer"
      ]
      var environment = ProcessInfo.processInfo.environment
      environment[IPCProcessEnvironment.mode] = mode
      environment[IPCProcessEnvironment.directory] = self.directory.path
      environment[IPCProcessEnvironment.database] = self.database.rawValue
      environment[IPCProcessEnvironment.ready] = self.file("ready-\(index)").path
      environment[IPCProcessEnvironment.result] = self.file("result-\(index)").path
      environment[IPCProcessEnvironment.expected] = String(expected)
      process.environment = environment
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      self.processes.append(process)
      return process
    }

    func waitUntilReady(_ count: Int) async throws {
      for index in 0..<count { try await waitForFile(self.file("ready-\(index)")) }
    }

    func start() throws { try touch(self.file("start")) }
    func stop() throws { try touch(self.file("stop")) }
    func result(_ index: Int) throws -> Int {
      try #require(Int(String(contentsOf: self.file("result-\(index)"), encoding: .utf8)))
    }

    func registrationCount() throws -> Int {
      let root = self.file("v1/d")
      guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
      return try FileManager.default
        .contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil
        )
        .reduce(0) {
          $0 + (try FileManager.default.contentsOfDirectory(atPath: $1.path).count)
        }
    }

    func waitForSuccessfulExit(_ process: Process) async throws {
      try await self.waitForExit(process)
      #expect(process.terminationStatus == 0)
    }

    func waitForExit(_ process: Process) async throws {
      try await waitUntil { !process.isRunning }
    }

    func suspend(_ process: Process) { ipcProcessSignal(process, SIGSTOP) }
    func resume(_ process: Process) { ipcProcessSignal(process, SIGCONT) }
    func kill(_ process: Process) { ipcProcessSignal(process, SIGKILL) }

    func cleanup() {
      for process in self.processes where process.isRunning {
        self.kill(process)
        process.waitUntilExit()
      }
      try? FileManager.default.removeItem(at: self.directory)
    }

    private func file(_ name: String) -> URL { self.directory.appending(path: name) }
  }

  private enum IPCProcessEnvironment {
    private static let prefix = "SQLITE_CROSS_IPC_HELPER_"
    static let mode = prefix + "MODE"
    static let directory = prefix + "DIRECTORY"
    static let database = prefix + "DATABASE"
    static let ready = prefix + "READY"
    static let result = prefix + "RESULT"
    static let expected = prefix + "EXPECTED_COUNT"
  }

  private func reachesBackPressure(
    _ transport: UnixDatagramDatabaseIPCTransport,
    message: DatabaseIPCMessage
  ) async throws -> Bool {
    for _ in 0..<10_000 {
      do { try await transport.send(message) } catch is DatabaseIPCPartialDeliveryError {
        return true
      }
    }
    return false
  }

  private func touch(_ url: URL) throws { try Data().write(to: url, options: .atomic) }

  private func waitForFile(_ url: URL, timeout: Duration = .seconds(10)) async throws {
    try await waitUntil(timeout: timeout) { FileManager.default.fileExists(atPath: url.path) }
  }

  private func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else { throw IPCProcessTimeout() }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private func ipcProcessSignal(_ process: Process, _ signal: Int32) {
    #if canImport(Darwin)
      _ = Darwin.kill(process.processIdentifier, signal)
    #else
      _ = Glibc.kill(process.processIdentifier, signal)
    #endif
  }

  private func ipcProcessExit(_ status: Int32) -> Never {
    #if canImport(Darwin)
      Darwin.exit(status)
    #else
      Glibc.exit(status)
    #endif
  }

  private struct IPCProcessTimeout: Error {}
#endif
