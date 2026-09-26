import Testing

@testable import SQLiteOrbit

@Test
func inMemoryTransportBroadcastsToEveryPeerButTheSender() async throws {
  let network = InMemoryIPCTransport.Network()
  let sender = InMemoryIPCTransport(network: network)
  let receivers = (0..<8).map { _ in InMemoryIPCTransport(network: network) }
  let senderRecorder = IPCMessageRecorder()
  let recorders = receivers.map { _ in IPCMessageRecorder() }
  let database = OrbitDatabaseIdentifier(rawValue: "broadcast")
  let subscriptions =
    try [sender.subscribe(to: database, onMessage: senderRecorder.append)]
    + zip(receivers, recorders)
    .map {
      try $0.subscribe(to: database, onMessage: $1.append)
    }
  let message = commit(database)

  try await sender.send(message)

  for recorder in recorders {
    #expect(recorder.values == [message])
  }
  #expect(senderRecorder.values.isEmpty)
  _ = subscriptions
}

@Test
func inMemoryTransportIsolatesDatabasesAndCancelsSynchronously() async throws {
  let network = InMemoryIPCTransport.Network()
  let sender = InMemoryIPCTransport(network: network)
  let receiver = InMemoryIPCTransport(network: network)
  let recorder = IPCMessageRecorder()
  let observed = OrbitDatabaseIdentifier(rawValue: "observed")
  let subscription = try receiver.subscribe(to: observed, onMessage: recorder.append)

  try await sender.send(commit(.init(rawValue: "other")))
  subscription.cancel()
  try await sender.send(commit(observed))

  #expect(recorder.values.isEmpty)
}

@Test
func inMemoryTransportInvokesEveryLocalSubscriptionOnce() async throws {
  let network = InMemoryIPCTransport.Network()
  let sender = InMemoryIPCTransport(network: network)
  let receiver = InMemoryIPCTransport(network: network)
  let first = IPCMessageRecorder()
  let second = IPCMessageRecorder()
  let database = OrbitDatabaseIdentifier(rawValue: "multi-subscription")
  let subscriptions = try [
    receiver.subscribe(to: database, onMessage: first.append),
    receiver.subscribe(to: database, onMessage: second.append)
  ]
  let message = commit(database)

  try await sender.send(message)

  #expect(first.values == [message])
  #expect(second.values == [message])
  _ = subscriptions
}

@Test
func inMemoryTransportsOnDifferentNetworksCannotSeeEachOther() async throws {
  let sender = InMemoryIPCTransport()
  let receiver = InMemoryIPCTransport()
  let recorder = IPCMessageRecorder()
  let database = OrbitDatabaseIdentifier(rawValue: "unreachable")
  let subscription = try receiver.subscribe(to: database, onMessage: recorder.append)

  try await sender.send(commit(database))

  #expect(recorder.values.isEmpty)
  _ = subscription
}

@Test
func inMemoryTransportStopsDeliveringAfterDeinit() async throws {
  let network = InMemoryIPCTransport.Network()
  let sender = InMemoryIPCTransport(network: network)
  let recorder = IPCMessageRecorder()
  let database = OrbitDatabaseIdentifier(rawValue: "released")

  var receiver: InMemoryIPCTransport? = InMemoryIPCTransport(network: network)
  let subscription = try receiver?.subscribe(to: database, onMessage: recorder.append)
  receiver = nil
  _ = subscription

  try await sender.send(commit(database))

  #expect(recorder.values.isEmpty)
}

@Suite
struct InMemoryIPCTransportRegionTests {
  private let database = OrbitDatabaseIdentifier(rawValue: "regions")
  private let items = OrbitDatabaseRegion(table: "items")
  private let lists = OrbitDatabaseRegion(table: "lists")

  @Test
  func senderSkipsAPeerWhoseRegionTheCommitMisses() async throws {
    let network = InMemoryIPCTransport.Network()
    let sender = InMemoryIPCTransport(network: network)
    let receiver = InMemoryIPCTransport(network: network)
    let recorder = IPCMessageRecorder()
    let subscription = try receiver.subscribe(
      to: database,
      region: items,
      onMessage: recorder.append
    )

    try await sender.send(commit(database, region: lists))
    try await sender.send(commit(database, region: .empty))
    try await sender.send(commit(database, region: OrbitDatabaseRegion(column: "id", in: "items")))
    try await sender.send(commit(database, region: .fullDatabase))

    #expect(
      recorder.values == [
        commit(database, region: OrbitDatabaseRegion(column: "id", in: "items")),
        commit(database, region: .fullDatabase)
      ]
    )
    _ = subscription
  }

  @Test
  func wideningTakesEffectForTheNextSend() async throws {
    let network = InMemoryIPCTransport.Network()
    let sender = InMemoryIPCTransport(network: network)
    let receiver = InMemoryIPCTransport(network: network)
    let recorder = IPCMessageRecorder()
    let subscription = try receiver.subscribe(
      to: database,
      region: items,
      onMessage: recorder.append
    )

    try await sender.send(commit(database, region: lists))
    try subscription.updateRegion(items.union(lists))
    #expect(receiver.advertisedRegion(for: database) == items.union(lists))
    try await sender.send(commit(database, region: lists))

    #expect(recorder.values == [commit(database, region: lists)])
    #expect(subscription.region == items.union(lists))
  }

  @Test
  func narrowingStopsTheSenderAtOnce() async throws {
    let network = InMemoryIPCTransport.Network()
    let sender = InMemoryIPCTransport(network: network)
    let receiver = InMemoryIPCTransport(network: network)
    let recorder = IPCMessageRecorder()
    let subscription = try receiver.subscribe(
      to: database,
      region: .fullDatabase,
      onMessage: recorder.append
    )

    try await sender.send(commit(database, region: lists))
    try subscription.updateRegion(items)
    try await sender.send(commit(database, region: lists))
    try await sender.send(commit(database, region: items))

    #expect(recorder.values == [commit(database, region: lists), commit(database, region: items)])
    #expect(receiver.advertisedRegion(for: database) == items)
  }

  @Test
  func peerAdvertisesTheUnionOfItsHandlersAndEachHandlerHearsOnlyItsOwn() async throws {
    let network = InMemoryIPCTransport.Network()
    let sender = InMemoryIPCTransport(network: network)
    let receiver = InMemoryIPCTransport(network: network)
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

    #expect(receiver.advertisedRegion(for: database) == items.union(lists))
    try await sender.send(commit(database, region: items))
    try await sender.send(commit(database, region: lists))

    #expect(itemsRecorder.values == [commit(database, region: items)])
    #expect(listsRecorder.values == [commit(database, region: lists)])
    _ = (itemsSubscription, listsSubscription)
  }

  @Test
  func cancellingAHandlerRecomputesTheAdvertisedUnion() async throws {
    let network = InMemoryIPCTransport.Network()
    let sender = InMemoryIPCTransport(network: network)
    let receiver = InMemoryIPCTransport(network: network)
    let itemsRecorder = IPCMessageRecorder()
    let itemsSubscription = try receiver.subscribe(
      to: database,
      region: items,
      onMessage: itemsRecorder.append
    )
    let listsSubscription = try receiver.subscribe(to: database, region: lists) { _ in }

    listsSubscription.cancel()
    #expect(receiver.advertisedRegion(for: database) == items)
    try await sender.send(commit(database, region: lists))
    itemsSubscription.cancel()
    #expect(receiver.advertisedRegion(for: database) == nil)
    try await sender.send(commit(database, region: items))

    #expect(itemsRecorder.values.isEmpty)
  }

  @Test
  func updatingACancelledSubscriptionLeavesTheOthersAlone() throws {
    let network = InMemoryIPCTransport.Network()
    let receiver = InMemoryIPCTransport(network: network)
    let kept = try receiver.subscribe(to: database, region: items) { _ in }
    let cancelled = try receiver.subscribe(to: database, region: lists) { _ in }

    cancelled.cancel()
    try cancelled.updateRegion(.fullDatabase)

    #expect(receiver.advertisedRegion(for: database) == items)
    _ = kept
  }

  @Test
  func subscriptionWithoutARegionHearsEveryCommit() async throws {
    let network = InMemoryIPCTransport.Network()
    let sender = InMemoryIPCTransport(network: network)
    let receiver = InMemoryIPCTransport(network: network)
    let recorder = IPCMessageRecorder()
    let subscription = try receiver.subscribe(to: database, onMessage: recorder.append)

    try await sender.send(commit(database, region: .empty))

    #expect(recorder.values == [commit(database, region: .empty)])
    #expect(receiver.advertisedRegion(for: database) == .fullDatabase)
    _ = subscription
  }
}

func commit(
  _ database: OrbitDatabaseIdentifier,
  region: OrbitDatabaseRegion = .fullDatabase
) -> OrbitIPCMessage {
  .transactionDidCommit(.init(databaseIdentifier: database, region: region))
}

final class IPCMessageRecorder: Sendable {
  private let messages = Lock([OrbitIPCMessage]())
  var values: [OrbitIPCMessage] { self.messages.withLock { $0 } }
  func append(_ message: OrbitIPCMessage) { self.messages.withLock { $0.append(message) } }

  func waitForCount(_ count: Int) async throws {
    try await waitUntil(timeout: .seconds(5)) { self.messages.withLock { $0.count } >= count }
  }
}
