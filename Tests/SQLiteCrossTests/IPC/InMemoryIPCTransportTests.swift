import Synchronization
import Testing

@testable import SQLiteCross

@Test
func inMemoryTransportDeliversToOnePeerAndNotToItself() async throws {
  let network = InMemoryIPCTransport.Network()
  let sender = InMemoryIPCTransport(network: network)
  let receiver = InMemoryIPCTransport(network: network)
  let senderMessages = IPCMessageRecorder()
  let receiverMessages = IPCMessageRecorder()
  let database = DatabaseIdentifier(rawValue: "example")
  let subscriptions = try [
    sender.subscribe(to: database, onMessage: senderMessages.append),
    receiver.subscribe(to: database, onMessage: receiverMessages.append)
  ]
  let message = commit(database)

  try await sender.send(message)

  #expect(receiverMessages.values == [message])
  #expect(senderMessages.values.isEmpty)
  _ = subscriptions
}

@Test
func inMemoryTransportBroadcastsToEveryPeer() async throws {
  let network = InMemoryIPCTransport.Network()
  let sender = InMemoryIPCTransport(network: network)
  let receivers = (0..<8).map { _ in InMemoryIPCTransport(network: network) }
  let recorders = receivers.map { _ in IPCMessageRecorder() }
  let database = DatabaseIdentifier(rawValue: "broadcast")
  let subscriptions = try zip(receivers, recorders)
    .map { try $0.subscribe(to: database, onMessage: $1.append) }
  let message = commit(database)

  try await sender.send(message)

  for recorder in recorders {
    #expect(recorder.values == [message])
  }
  _ = subscriptions
}

@Test
func inMemoryTransportIsolatesDatabasesAndCancelsSynchronously() async throws {
  let network = InMemoryIPCTransport.Network()
  let sender = InMemoryIPCTransport(network: network)
  let receiver = InMemoryIPCTransport(network: network)
  let recorder = IPCMessageRecorder()
  let observed = DatabaseIdentifier(rawValue: "observed")
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
  let database = DatabaseIdentifier(rawValue: "multi-subscription")
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
  let database = DatabaseIdentifier(rawValue: "unreachable")
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
  let database = DatabaseIdentifier(rawValue: "released")

  var receiver: InMemoryIPCTransport? = InMemoryIPCTransport(network: network)
  let subscription = try receiver?.subscribe(to: database, onMessage: recorder.append)
  receiver = nil
  _ = subscription

  try await sender.send(commit(database))

  #expect(recorder.values.isEmpty)
}

private func commit(_ database: DatabaseIdentifier) -> DatabaseIPCMessage {
  .transactionDidCommit(.init(databaseIdentifier: database))
}

private final class IPCMessageRecorder: Sendable {
  private let messages = Mutex([DatabaseIPCMessage]())
  var values: [DatabaseIPCMessage] { self.messages.withLock { $0 } }
  func append(_ message: DatabaseIPCMessage) { self.messages.withLock { $0.append(message) } }
}
