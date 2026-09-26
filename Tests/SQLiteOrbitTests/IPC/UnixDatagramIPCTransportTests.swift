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
      #expect(try UnixSystem.sendDatagram(datagram, on: descriptor))

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
    var subscription: OrbitRegionSubscription? = try first?.subscribe(to: database) { _ in }
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
    var subscription: OrbitRegionSubscription? = try transport?.subscribe(to: database) { _ in }
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
  func regionsDecideWhichPeersASendReaches() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let database = OrbitDatabaseIdentifier(rawValue: "regions")
    let sender = try ipcTransport(directory)
    let receiver = try ipcTransport(directory)
    let recorder = IPCMessageRecorder()
    let subscription = try receiver.subscribe(
      to: database,
      region: OrbitDatabaseRegion(table: "items"),
      onMessage: recorder.append
    )
    let disjoint = regionCommit(database, OrbitDatabaseRegion(table: "lists"))
    let overlapping = regionCommit(database, OrbitDatabaseRegion(column: "title", in: "items"))

    #expect(try sender.peers(concernedWith: disjoint).isEmpty)
    #expect(try sender.peers(concernedWith: overlapping).count == 1)
    try await sender.send(disjoint)
    try await sender.send(overlapping)
    try await recorder.waitForCount(1)
    try await Task.sleep(for: .milliseconds(20))

    #expect(recorder.values == [overlapping])
    _ = subscription
  }

  @Test
  func aSendThatStartsAfterARegionWidensHonorsIt() async throws {
    // Every update widens to one more table, so each send has to see the marker rewritten by the
    // update that just returned. The first also narrows away the table the subscription started
    // with. The receiver judges each commit by its handler's region when the commit arrives, so
    // the region only grows: a commit sent under an older one must still be let through.
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let database = OrbitDatabaseIdentifier(rawValue: "widening")
    let sender = try ipcTransport(directory)
    let receiver = try ipcTransport(directory)
    let recorder = IPCMessageRecorder()
    let subscription = try receiver.subscribe(
      to: database,
      region: OrbitDatabaseRegion(table: "t0"),
      onMessage: recorder.append
    )
    var expected: [OrbitIPCMessage] = []
    var region = OrbitDatabaseRegion.empty

    for index in 1...200 {
      let table = OrbitDatabaseRegion(table: "t\(index)")
      region.formUnion(table)
      try subscription.updateRegion(region)
      #expect(try sender.peers(concernedWith: regionCommit(database, .init(table: "t0"))).isEmpty)
      let message = regionCommit(database, table)
      expected.append(message)
      try await sender.send(message)
    }
    try await recorder.waitForCount(expected.count)

    #expect(recorder.values == expected)
  }

  @Test
  func anEndpointAdvertisesTheUnionOfItsHandlersRegions() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let database = OrbitDatabaseIdentifier(rawValue: "union")
    let items = OrbitDatabaseRegion(table: "items")
    let lists = OrbitDatabaseRegion(table: "lists")
    let sender = try ipcTransport(directory)
    let receiver = try ipcTransport(directory)
    let registry = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "observer")
    let itemsRecorder = IPCMessageRecorder()
    let listsRecorder = IPCMessageRecorder()
    let itemsSubscription = try receiver.subscribe(
      to: database,
      region: items,
      onMessage: itemsRecorder.append
    )
    let listsSubscription = try receiver.subscribe(
      to: database,
      region: lists,
      onMessage: listsRecorder.append
    )
    func advertised() throws -> [OrbitDatabaseRegion] {
      Array(try registry.advertisements(coordinationKey: database.coordinationKey).values)
    }

    #expect(receiver.advertisedRegion(for: database) == items.union(lists))
    #expect(try advertised() == [items.union(lists)])

    // Each handler hears only about its own region, whatever the union lets through.
    try await sender.send(regionCommit(database, lists))
    try await listsRecorder.waitForCount(1)
    #expect(itemsRecorder.values.isEmpty)

    listsSubscription.cancel()
    #expect(receiver.advertisedRegion(for: database) == items)
    #expect(try advertised() == [items])
    #expect(try sender.peers(concernedWith: regionCommit(database, lists)).isEmpty)

    try itemsSubscription.updateRegion(.empty)
    #expect(try advertised() == [.empty])
    #expect(try sender.peers(concernedWith: regionCommit(database, items)).isEmpty)

    itemsSubscription.cancel()
    #expect(receiver.advertisedRegion(for: database) == nil)
    #expect(try advertised().isEmpty)
  }

  @Test
  func aPeerIsNeverSentACommitItsRegionMisses() async throws {
    // The receiver stops draining its queue, so a sender that sent it commits outside its region
    // would find the queue full long before running out of them.
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let database = OrbitDatabaseIdentifier(rawValue: "unsent")
    let receiver = try StalledReceiver(
      directory: directory,
      database: database,
      region: OrbitDatabaseRegion(table: "items")
    )
    let sender = try ipcTransport(directory)
    try await sender.send(regionCommit(database, OrbitDatabaseRegion(table: "items")))

    for _ in 0..<2_000 {
      try await sender.send(regionCommit(database, OrbitDatabaseRegion(table: "lists")))
    }
    #expect(
      try await reachesBackPressure(
        sender,
        message: regionCommit(database, OrbitDatabaseRegion(table: "items"))
      )
    )
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
    private let subscription: OrbitRegionSubscription

    init(
      directory: URL,
      database: OrbitDatabaseIdentifier,
      region: OrbitDatabaseRegion = .fullDatabase
    ) throws {
      let recorder = self.recorder
      let gate = self.gate
      let isStalled = Lock(true)
      self.transport = try ipcTransport(directory)
      self.subscription = try self.transport.subscribe(to: database, region: region) { message in
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

  private func regionCommit(
    _ database: OrbitDatabaseIdentifier,
    _ region: OrbitDatabaseRegion
  ) -> OrbitIPCMessage {
    .transactionDidCommit(.init(databaseIdentifier: database, region: region))
  }

  private func ipcTestDirectory() throws -> URL {
    try makeShortTemporaryDirectory("ipc")
  }

  private func ipcTransport(_ directory: URL) throws -> UnixDatagramIPCTransport {
    try .init(configuration: .init(directory: directory, backPressure: .fail))
  }

  private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
#endif
