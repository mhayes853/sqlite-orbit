#if canImport(Darwin) || canImport(Glibc)
  import Foundation
  import Synchronization
  import Testing

  @testable import SQLiteOrbit

  @Test
  func unixDatagramTransportDeliversToOnePeerAndNotToItself() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let sender = try ipcTransport(directory)
    let receiver = try ipcTransport(directory)
    let senderMessages = IPCMessageRecorder()
    let receiverMessages = IPCMessageRecorder()
    let database = DatabaseIdentifier(rawValue: "example")
    let subscriptions = try [
      sender.subscribe(to: database, onMessage: senderMessages.append),
      receiver.subscribe(to: database, onMessage: receiverMessages.append)
    ]
    let message = commit(database)

    try await sender.send(message)
    try await receiverMessages.waitForCount(1)
    try await Task.sleep(for: .milliseconds(20))

    #expect(receiverMessages.values == [message])
    #expect(senderMessages.values.isEmpty)
    _ = subscriptions
  }

  @Test
  func unixDatagramTransportBroadcastsToEveryPeer() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let sender = try ipcTransport(directory)
    let receivers = try (0..<8).map { _ in try ipcTransport(directory) }
    let recorders = receivers.map { _ in IPCMessageRecorder() }
    let database = DatabaseIdentifier(rawValue: "broadcast")
    let subscriptions = try zip(receivers, recorders)
      .map {
        try $0.subscribe(to: database, onMessage: $1.append)
      }
    let message = commit(database)

    try await sender.send(message)
    for recorder in recorders {
      try await recorder.waitForCount(1)
      #expect(recorder.values == [message])
    }
    _ = subscriptions
  }

  @Test
  func unixDatagramTransportIsolatesDatabasesAndCancelsSynchronously() async throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let sender = try ipcTransport(directory)
    let receiver = try ipcTransport(directory)
    let recorder = IPCMessageRecorder()
    let observed = DatabaseIdentifier(rawValue: "observed")
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
    let database = DatabaseIdentifier(rawValue: "malformed")
    let subscription = try receiver.subscribe(to: database, onMessage: recorder.append)
    let registry = try DatabaseIPCEndpointRegistry(directory: directory, endpointName: "malformed")
    let socket = try UnixDatagramSocket(
      path: registry.socketPath,
      receiveBufferByteCount: 65_535
    )
    let peer = try #require(registry.peers(databaseIdentifier: database).first)

    _ = try socket.send([0xff, 0, 1], to: peer.socketPath)
    let message = commit(database)
    try await sender.send(message)
    try await recorder.waitForCount(1)

    #expect(recorder.values == [message])
    _ = subscription
  }

  @Test
  func sharedReturnsTheSameTransportForRepeatedCallsWithTheSameConfiguration() throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let configuration = UnixDatagramDatabaseIPCTransport.Configuration(
      directory: directory,
      backPressure: .fail
    )

    let first = try UnixDatagramDatabaseIPCTransport.shared(configuration: configuration)
    let second = try UnixDatagramDatabaseIPCTransport.shared(configuration: configuration)

    #expect(first === second)
  }

  @Test
  func sharedReturnsDifferentTransportsForDifferentConfigurations() throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    let fail = UnixDatagramDatabaseIPCTransport.Configuration(
      directory: directory,
      backPressure: .fail
    )
    let suspend = UnixDatagramDatabaseIPCTransport.Configuration(
      directory: directory,
      backPressure: .suspend(upTo: .milliseconds(1))
    )

    let first = try UnixDatagramDatabaseIPCTransport.shared(configuration: fail)
    let second = try UnixDatagramDatabaseIPCTransport.shared(configuration: suspend)

    #expect(first !== second)
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
    let configuration = UnixDatagramDatabaseIPCTransport.Configuration(
      directory: directory,
      backPressure: .fail
    )
    let registry = try DatabaseIPCEndpointRegistry(directory: directory, endpointName: "observer")
    let database = DatabaseIdentifier(rawValue: "shared-lifetime")

    var first: UnixDatagramDatabaseIPCTransport? = try .shared(configuration: configuration)
    var subscription: OrbitSubscription? = try first?.subscribe(to: database) { _ in }
    let firstEndpoint = try #require(registry.peers(databaseIdentifier: database).first)
      .endpointName

    subscription = nil
    first = nil

    let second = try UnixDatagramDatabaseIPCTransport.shared(configuration: configuration)
    let secondSubscription = try second.subscribe(to: database) { _ in }
    let secondEndpoint = try #require(registry.peers(databaseIdentifier: database).first)
      .endpointName

    #expect(secondEndpoint != firstEndpoint)
    _ = secondSubscription
  }

  @Test
  func unixDatagramTransportRejectsInvalidConfiguration() throws {
    let directory = try ipcTestDirectory()
    defer { remove(directory) }
    for (maximum, receiveBuffer) in [(0, 256 * 1024), (1024, 512)] {
      #expect(throws: (any Error).self) {
        try UnixDatagramDatabaseIPCTransport(
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

  private func ipcTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "sqlite-orbit-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func ipcTransport(_ directory: URL) throws -> UnixDatagramDatabaseIPCTransport {
    try .init(configuration: .init(directory: directory, backPressure: .fail))
  }

  private func commit(_ database: DatabaseIdentifier) -> DatabaseIPCMessage {
    .transactionDidCommit(.init(databaseIdentifier: database))
  }

  private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

  private final class IPCMessageRecorder: Sendable {
    private let messages = Mutex([DatabaseIPCMessage]())
    var values: [DatabaseIPCMessage] { self.messages.withLock { $0 } }
    func append(_ message: DatabaseIPCMessage) { self.messages.withLock { $0.append(message) } }

    func waitForCount(_ count: Int) async throws {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(5))
      while self.messages.withLock({ $0.count }) < count {
        guard clock.now < deadline else { throw IPCMessageRecorderTimeout() }
        try await Task.sleep(for: .milliseconds(2))
      }
    }
  }

  private struct IPCMessageRecorderTimeout: Error {}
#endif
