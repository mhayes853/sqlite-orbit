#if canImport(Darwin) || os(Linux) || os(Android)
  import Dispatch
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Test
  func unixDatagramTransportBroadcastsToEveryPeerButTheSender() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let sender = try ipcTransport(directory)
    let receivers = try (0..<8).map { _ in try ipcTransport(directory) }
    let senderRecorder = IPCMessageRecorder()
    let recorders = receivers.map { _ in IPCMessageRecorder() }
    let database = OrbitDatabaseIdentifier(rawValue: "broadcast")
    let subscriptions =
      try [sender.subscribe(to: database, onMessage: senderRecorder.append)]
      + zip(receivers, recorders)
      .map {
        try $0.subscribe(to: database, onMessage: $1.append)
      }
    let message = OrbitIPCMessage.transactionDidCommit(
      .init(
        databaseIdentifier: database,
        region: OrbitDatabaseRegion.fullDatabase.subtracting(
          OrbitDatabaseRegion(column: "title", in: "items")
        )
      )
    )

    try await sender.send(message)
    for recorder in recorders {
      try await recorder.waitForCount(1)
      #expect(recorder.values == [message])
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(senderRecorder.values.isEmpty)
    _ = subscriptions
  }

  @Test
  func unixDatagramTransportBroadensARegionThatDoesNotFit() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let configuration = UnixDatagramIPCTransport.Configuration(
      directory: directory,
      backPressure: .fail,
      // Room for the full database's 21 bytes, and not for the column's 50.
      maximumDatagramByteCount: 40,
      receiveBufferByteCount: 4_096
    )
    let sender = try UnixDatagramIPCTransport(configuration: configuration)
    let receiver = try UnixDatagramIPCTransport(configuration: configuration)
    let recorder = IPCMessageRecorder()
    let database = OrbitDatabaseIdentifier(rawValue: "d")
    let subscription = try receiver.subscribe(to: database, onMessage: recorder.append)

    try await sender.send(
      .transactionDidCommit(
        .init(
          databaseIdentifier: database,
          region: OrbitDatabaseRegion(column: "title", in: "items")
        )
      )
    )
    try await recorder.waitForCount(1)

    #expect(
      recorder.values == [
        .transactionDidCommit(.init(databaseIdentifier: database, region: .fullDatabase))
      ]
    )
    _ = subscription
  }

  @Test
  func unixDatagramTransportIsolatesDatabasesAndCancelsSynchronously() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let sender = try ipcTransport(directory)
    let receiver = try ipcTransport(directory)
    let recorder = IPCMessageRecorder()
    let observed = OrbitDatabaseIdentifier(rawValue: "observed")
    let subscription = try receiver.subscribe(to: observed, onMessage: recorder.append)

    try await sender.send(commit(.init(rawValue: "other")))
    subscription.cancel()
    try await sender.send(commit(observed))
    try await Task.sleep(for: .milliseconds(20))

    #expect(recorder.values.isEmpty)
  }

  @Test
  func unixDatagramTransportContinuesAfterMalformedDatagrams() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let sender = try ipcTransport(directory)
    let receiver = try ipcTransport(directory)
    let recorder = IPCMessageRecorder()
    let database = OrbitDatabaseIdentifier(rawValue: "malformed")
    let subscription = try receiver.subscribe(to: database, onMessage: recorder.append)
    let registry = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "malformed")
    let peer = try #require(registry.peers(databaseIdentifier: database).first)
    let descriptor = try UnixSystem.makeConnectedDatagramSocket(path: peer.socketPath)
    defer { UnixSystem.closeDescriptor(descriptor) }
    // One that fills the receive buffer, which the transport sizes a byte past the longest datagram
    // it accepts, is dropped rather than decoded from a prefix.
    let tooLong =
      try OrbitIPCWireProtocol.encode(commit(database))
      + [UInt8](repeating: 0, count: 60 * 1024)

    for datagram in [[0xff, 0, 1], tooLong] {
      #expect(try datagram.withUnsafeBytes { try UnixSystem.sendDatagram($0, on: descriptor) })
    }
    let message = commit(database)
    try await sender.send(message)
    try await recorder.waitForCount(1)

    #expect(recorder.values == [message])
    _ = subscription
  }

  @Test
  func sharedReusesOnlyTransportsWithTheSameConfiguration() throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let configuration = UnixDatagramIPCTransport.Configuration(
      directory: directory,
      backPressure: .fail
    )
    let otherConfiguration = UnixDatagramIPCTransport.Configuration(
      directory: directory,
      backPressure: .suspend(upTo: .milliseconds(1))
    )

    let first = try UnixDatagramIPCTransport.shared(configuration: configuration)
    let second = try UnixDatagramIPCTransport.shared(configuration: configuration)
    let other = try UnixDatagramIPCTransport.shared(configuration: otherConfiguration)

    #expect(first === second)
    #expect(first !== other)
  }

  @Test
  func sharedRecreatesTheTransportOnceEveryReferenceIsReleased() throws {
    // Peers discover a process, not a database, so every database configured alike must reuse one
    // transport for as long as anything holds it, and get a fresh, working one once nothing does.
    // Object identity alone would not prove this: a freed transport's address can be reused by the
    // very next allocation. Cancelling a subscription alone would not prove it either: that empties
    // the registration whether or not the transport behind it was actually recreated. What only a
    // genuinely new transport produces is a new socket endpoint, generated once at construction, so
    // this compares the endpoint a fresh subscription registers under before and after release.
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let configuration = UnixDatagramIPCTransport.Configuration(
      directory: directory,
      backPressure: .fail
    )
    let registry = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "observer")
    let database = OrbitDatabaseIdentifier(rawValue: "shared-lifetime")

    var first: UnixDatagramIPCTransport? = try .shared(configuration: configuration)
    var subscription: OrbitSubscription? = try first?.subscribe(to: database) { _ in }
    let firstEndpoint = try withExtendedLifetime(subscription) {
      try #require(registry.peers(databaseIdentifier: database).first).endpointName
    }

    subscription = nil
    first = nil

    let second = try UnixDatagramIPCTransport.shared(configuration: configuration)
    let secondSubscription = try second.subscribe(to: database) { _ in }
    let secondEndpoint = try #require(registry.peers(databaseIdentifier: database).first)
      .endpointName

    #expect(secondEndpoint != firstEndpoint)
    _ = secondSubscription
  }

  @Test
  func releasingATransportWithdrawsEverythingAPeerFindsItBy() async throws {
    // The receive source is only done with the socket's descriptor once dispatch has finished
    // cancelling it, which is after the transport is gone. Neither of the things a peer looks the
    // endpoint up by — its marker and its socket path — may wait for that.
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let registry = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "observer")
    let database = OrbitDatabaseIdentifier(rawValue: "socket-lifetime")

    var transport: UnixDatagramIPCTransport? = try ipcTransport(directory)
    var subscription: OrbitSubscription? = try transport?.subscribe(to: database) { _ in }
    let socketPath = try withExtendedLifetime(subscription) {
      try #require(registry.peers(databaseIdentifier: database).first).socketPath
    }
    #expect(FileManager.default.fileExists(atPath: socketPath))

    subscription = nil
    transport = nil

    #expect(try registry.peers(databaseIdentifier: database).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: socketPath))
  }

  @Test
  func aHandlerCanReleaseTheLastReferenceToItsTransport() async throws {
    // The handler runs on the transport's own thread, so releasing the transport there must
    // neither wait for that thread nor close the descriptors it is about to go back to waiting on.
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let registry = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "observer")
    let database = OrbitDatabaseIdentifier(rawValue: "self-release")
    let sender = try ipcTransport(directory)
    let held = Lock<UnixDatagramIPCTransport?>(try ipcTransport(directory))
    let subscription = try held.withLock { transport in
      try transport!.subscribe(to: database) { _ in held.withLock { $0 = nil } }
    }
    let socketPath = try #require(registry.peers(databaseIdentifier: database).first).socketPath

    try await sender.send(commit(database))
    try await waitUntil { held.withLock { $0 == nil } }

    #expect(try registry.peers(databaseIdentifier: database).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: socketPath))
    _ = subscription
  }

  @Test
  func suspendedSendsBatchBehindAStalledReceiverAndArriveInOrder() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let database = OrbitDatabaseIdentifier(rawValue: "stalled")
    let receiver = try StalledReceiver(directory: directory, database: database)
    // Small datagrams, so what waits for the receiver spans several batches.
    let sender = try UnixDatagramIPCTransport(
      configuration: .init(
        directory: directory,
        backPressure: .suspend(upTo: .seconds(30)),
        maximumDatagramByteCount: 256
      )
    )

    let sends = try await sendUntilWaiting(sender, database: database, pendingCount: 100)
    receiver.resume()
    for task in sends.tasks {
      try await task.value
    }
    try await receiver.recorder.waitForCount(sends.messages.count)

    #expect(receiver.recorder.values == sends.messages)
    #expect(sender.pendingMessageCount == 0)
  }

  @Test
  func cancellingASuspendedSendWithdrawsItsMessage() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let database = OrbitDatabaseIdentifier(rawValue: "cancelled")
    let receiver = try StalledReceiver(directory: directory, database: database)
    let sender = try UnixDatagramIPCTransport(
      configuration: .init(directory: directory, backPressure: .suspend(upTo: .seconds(30)))
    )
    let sends = try await sendUntilWaiting(sender, database: database, pendingCount: 3)

    let withdrawn = stalledCommit(database, index: -1)
    let cancelled = Task { try await sender.send(withdrawn) }
    try await waitUntil { sender.pendingMessageCount == 4 }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(sender.pendingMessageCount == 3)

    receiver.resume()
    for task in sends.tasks {
      try await task.value
    }
    try await receiver.recorder.waitForCount(sends.messages.count)
    #expect(receiver.recorder.values == sends.messages)
  }

  @Test
  func aSuspendedSendFailsAtItsDeadlineAndLeavesNothingBehind() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let database = OrbitDatabaseIdentifier(rawValue: "expired")
    let receiver = try StalledReceiver(directory: directory, database: database)
    let sender = try UnixDatagramIPCTransport(
      configuration: .init(directory: directory, backPressure: .suspend(upTo: .milliseconds(20)))
    )

    var failure: OrbitIPCPartialDeliveryError?
    for index in 0..<10_000 where failure == nil {
      do {
        try await sender.send(stalledCommit(database, index: index))
      } catch let error as OrbitIPCPartialDeliveryError {
        failure = error
      }
    }

    #expect(
      failure
        == OrbitIPCPartialDeliveryError(
          discoveredPeerCount: 1,
          deliveredPeerCount: 0,
          failedPeerCount: 1
        )
    )
    #expect(sender.pendingMessageCount == 0)
    receiver.resume()
  }

  @Test
  func unixDatagramTransportRejectsInvalidConfiguration() throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    for (maximum, receiveBuffer) in [(0, 256 * 1024), (1024, 512)] {
      #expect(throws: (any Error).self) {
        try UnixDatagramIPCTransport(
          configuration: .init(
            directory: directory,
            backPressure: .fail,
            maximumDatagramByteCount: maximum,
            receiveBufferByteCount: receiveBuffer
          )
        )
      }
    }
  }

  /// A receiver whose handler blocks on the first message until ``resume()``, so its socket's
  /// queue fills and senders see it as full.
  private final class StalledReceiver: Sendable {
    let recorder = IPCMessageRecorder()
    private let gate = DispatchSemaphore(value: 0)
    private let transport: UnixDatagramIPCTransport
    private let subscription: OrbitSubscription

    init(directory: URL, database: OrbitDatabaseIdentifier) throws {
      let recorder = self.recorder
      let gate = self.gate
      let isStalled = Lock(true)
      self.transport = try ipcTransport(directory)
      self.subscription = try self.transport.subscribe(to: database) { message in
        recorder.append(message)
        let stalls = isStalled.withLock { isStalled in
          defer { isStalled = false }
          return isStalled
        }
        if stalls { gate.wait() }
      }
    }

    deinit {
      // A test that fails before resuming must not leave the transport's thread blocked for good.
      self.gate.signal()
    }

    func resume() { self.gate.signal() }
  }

  /// Sends commits in order, each once the one before it has been delivered or has started
  /// waiting, until `pendingCount` of them wait for a full receiver.
  ///
  /// - Returns: The tasks sending every commit, and the commits, in the order they were sent.
  private func sendUntilWaiting(
    _ sender: UnixDatagramIPCTransport,
    database: OrbitDatabaseIdentifier,
    pendingCount: Int
  ) async throws -> (tasks: [Task<Void, any Error>], messages: [OrbitIPCMessage]) {
    let delivered = Lock(0)
    var tasks: [Task<Void, any Error>] = []
    var messages: [OrbitIPCMessage] = []
    while sender.pendingMessageCount < pendingCount {
      guard messages.count < 10_000 else { throw TestTimeout() }
      let message = stalledCommit(database, index: messages.count)
      messages.append(message)
      tasks.append(
        Task { @Sendable in
          try await sender.send(message)
          delivered.withLock { $0 += 1 }
        }
      )
      let sent = messages.count
      try await waitUntil { delivered.withLock { $0 } + sender.pendingMessageCount == sent }
    }
    return (tasks, messages)
  }

  /// A commit no other index produces, so the order commits arrive in shows.
  private func stalledCommit(_ database: OrbitDatabaseIdentifier, index: Int) -> OrbitIPCMessage {
    .transactionDidCommit(
      .init(
        databaseIdentifier: database,
        region: OrbitDatabaseRegion(column: "c\(index)", in: "items")
      )
    )
  }

  private func ipcTestDirectory() throws -> URL {
    try makeShortTemporaryDirectory("ipc")
  }

  private func ipcTransport(_ directory: URL) throws -> UnixDatagramIPCTransport {
    try .init(configuration: .init(directory: directory, backPressure: .fail))
  }

  private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
#endif
