#if canImport(Darwin) || canImport(Glibc)
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
      maximumDatagramByteCount: 12,
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

  private func ipcTestDirectory() throws -> URL {
    try makeShortTemporaryDirectory("ipc")
  }

  private func ipcTransport(_ directory: URL) throws -> UnixDatagramIPCTransport {
    try .init(configuration: .init(directory: directory, backPressure: .fail))
  }

  private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
#endif
