#if canImport(Darwin) || os(Linux) || os(Android)
  import Dispatch
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Test
  func unixDatagramTransportBroadcastsToEveryPeerButTheSender() async throws {
    try await withTemporaryDirectory("ipc") { directory in
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
  }

  @Test
  func unixDatagramTransportBroadensARegionThatDoesNotFit() async throws {
    try await withTemporaryDirectory("ipc") { directory in
      let configuration = UnixDatagramIPCTransport.Configuration(
        directory: directory,
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
  }

  @Test
  func unixDatagramTransportIsolatesDatabasesAndCancelsSynchronously() async throws {
    try await withTemporaryDirectory("ipc") { directory in
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
  }

  @Test
  func unixDatagramTransportContinuesAfterMalformedDatagrams() async throws {
    try await withTemporaryDirectory("ipc") { directory in
      let sender = try ipcTransport(directory)
      let receiver = try ipcTransport(directory)
      let recorder = IPCMessageRecorder()
      let database = OrbitDatabaseIdentifier(rawValue: "malformed")
      let subscription = try receiver.subscribe(to: database, onMessage: recorder.append)
      let registry = try unixDatagramRegistry(directory, endpointName: "malformed")
      let peer = try #require(registry.peers(databaseIdentifier: database).first)
      guard let socket = try UnixDatagramSocket.connect(to: peer.socketPath) else {
        Issue.record("Nothing is bound at \(peer.socketPath)")
        return
      }
      // One that fills the receive buffer, which the transport sizes a byte past the longest datagram
      // it accepts, is dropped rather than decoded from a prefix.
      let tooLong =
        try UnixDatagramWireProtocol.encode(commit(database))
        + [UInt8](repeating: 0, count: 60 * 1024)

      for datagram in [[0xff, 0, 1], tooLong] {
        #expect(socket.send(datagram) == .sent)
      }
      let message = commit(database)
      try await sender.send(message)
      try await recorder.waitForCount(1)

      #expect(recorder.values == [message])
      _ = subscription
    }
  }

  @Test
  func sharedReusesOnlyTransportsWithTheSameConfiguration() throws {
    try withTemporaryDirectory("ipc") { directory in
      let configuration = UnixDatagramIPCTransport.Configuration(directory: directory)
      let otherConfiguration = UnixDatagramIPCTransport.Configuration(
        directory: directory,
        receiveBufferByteCount: 128 * 1024
      )

      let first = try UnixDatagramIPCTransport.shared(configuration: configuration)
      let second = try UnixDatagramIPCTransport.shared(configuration: configuration)
      let other = try UnixDatagramIPCTransport.shared(configuration: otherConfiguration)

      #expect(first === second)
      #expect(first !== other)
    }
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
    try withTemporaryDirectory("ipc") { directory in
      let configuration = UnixDatagramIPCTransport.Configuration(directory: directory)
      let registry = try unixDatagramRegistry(directory, endpointName: "observer")
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
  }

  @Test
  func releasingATransportWithdrawsEverythingAPeerFindsItBy() async throws {
    // The receive source is only done with the socket's descriptor once dispatch has finished
    // cancelling it, which is after the transport is gone. Neither of the things a peer looks the
    // endpoint up by — its marker and its socket path — may wait for that.
    try await withTemporaryDirectory("ipc") { directory in
      let registry = try unixDatagramRegistry(directory, endpointName: "observer")
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
  }

  @Test
  func aHandlerCanReleaseTheLastReferenceToItsTransport() async throws {
    // The handler runs on the transport's own thread, so releasing the transport there must
    // neither wait for that thread nor close the descriptors it is about to go back to waiting on.
    try await withTemporaryDirectory("ipc") { directory in
      let registry = try unixDatagramRegistry(directory, endpointName: "observer")
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
  }

  @Test
  func aHeldReceiverIsSentWhatItMissedOnceItResumes() async throws {
    // The receiver stops reading at its first commit, so its queue fills. The commit it has no
    // room for, and every one after it, are merged into what it is owed, which reaches it as one
    // commit once it reads again, after everything its queue held.
    try await withTemporaryDirectory("ipc") { directory in
      let database = OrbitDatabaseIdentifier(rawValue: "stalled")
      let receiver = try HeldReceiver(directory: directory, database: database)
      let sender = try ipcTransport(directory)

      let (queued, first) = try await receiver.fill(from: sender)
      var owed = first
      for index in 10_000..<10_003 {
        try await sender.send(columnCommit(database, index))
        owed.formUnion(itemsColumn(index))
      }
      #expect(Array(sender.owedRegions.values) == [[database: owed]])

      receiver.resume()
      try await receiver.recorder.waitForCount(queued.count + 1)
      try await waitUntil { sender.owedRegions.isEmpty }

      #expect(receiver.recorder.values == queued + [commit(database, region: owed)])
    }
  }

  @Test
  func aSendThatStartsAfterARegionWidensHonorsIt() async throws {
    // Every update widens to one more table, so each send has to see the marker rewritten by the
    // update that just returned. The first also narrows away the table the subscription started
    // with. The receiver judges each commit by its handler's region when the commit arrives, so
    // the region only grows: a commit sent under an older one must still be let through.
    try await withTemporaryDirectory("ipc") { directory in
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
        #expect(
          try sender.peers(concernedWith: commit(database, region: .init(table: "t0"))).isEmpty
        )
        let message = commit(database, region: table)
        expected.append(message)
        try await sender.send(message)
      }
      try await recorder.waitForCount(expected.count)

      #expect(recorder.values == expected)
    }
  }

  @Test
  func anEndpointAdvertisesTheUnionOfItsHandlersRegions() async throws {
    try await withTemporaryDirectory("ipc") { directory in
      let database = OrbitDatabaseIdentifier(rawValue: "union")
      let items = OrbitDatabaseRegion(table: "items")
      let lists = OrbitDatabaseRegion(table: "lists")
      let sender = try ipcTransport(directory)
      let receiver = try ipcTransport(directory)
      let registry = try unixDatagramRegistry(
        directory,
        endpointName: "observer",
        watchesDirectories: false
      )
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
        Array(try registry.peerRegions(for: database).values)
      }

      #expect(receiver.advertisedRegion(for: database) == items.union(lists))
      #expect(try advertised() == [items.union(lists)])

      // Each handler hears only about its own region, whatever the union lets through.
      try await sender.send(commit(database, region: lists))
      try await listsRecorder.waitForCount(1)
      #expect(itemsRecorder.values.isEmpty)

      listsSubscription.cancel()
      #expect(receiver.advertisedRegion(for: database) == items)
      #expect(try advertised() == [items])
      #expect(try sender.peers(concernedWith: commit(database, region: lists)).isEmpty)

      try itemsSubscription.updateRegion(.empty)
      #expect(try advertised() == [.empty])
      #expect(try sender.peers(concernedWith: commit(database, region: items)).isEmpty)

      itemsSubscription.cancel()
      #expect(receiver.advertisedRegion(for: database) == nil)
      #expect(try advertised().isEmpty)
    }
  }

  @Test
  func aPeerIsSentOnlyTheCommitsItsRegionAdmits() async throws {
    // The receiver stops draining its queue at the first commit, so a sender that sent it commits
    // outside its region would find the queue full, and owe it, long before running out of them.
    try await withTemporaryDirectory("ipc") { directory in
      let database = OrbitDatabaseIdentifier(rawValue: "regions")
      let receiver = try HeldReceiver(
        directory: directory,
        database: database,
        region: OrbitDatabaseRegion(table: "items")
      )
      let sender = try ipcTransport(directory)
      let disjoint = commit(database, region: OrbitDatabaseRegion(table: "lists"))
      let overlapping = commit(database, region: OrbitDatabaseRegion(column: "title", in: "items"))
      #expect(try sender.peers(concernedWith: disjoint).isEmpty)
      #expect(try sender.peers(concernedWith: overlapping).count == 1)

      try await sender.send(overlapping)
      for _ in 0..<2_000 {
        try await sender.send(disjoint)
      }
      #expect(sender.owedRegions.isEmpty)
      #expect(try await reachesAFullQueue(sender, message: overlapping))
      #expect(receiver.recorder.values == [overlapping])
      receiver.resume()
    }
  }

  @Test
  func unixDatagramTransportRejectsInvalidConfiguration() throws {
    try withTemporaryDirectory("ipc") { directory in
      for (maximum, receiveBuffer) in [(0, 256 * 1024), (1024, 512)] {
        #expect(throws: (any Error).self) {
          try UnixDatagramIPCTransport(
            configuration: .init(
              directory: directory,
              maximumDatagramByteCount: maximum,
              receiveBufferByteCount: receiveBuffer
            )
          )
        }
      }
    }
  }

  /// A receiver whose handler holds the transport's thread at the first message until
  /// ``resume()``, as a suspended process holds it, so its queue fills and senders see it as full,
  /// and it repairs nothing.
  final class HeldReceiver: Sendable {
    let recorder = IPCMessageRecorder()
    private let database: OrbitDatabaseIdentifier
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
      let isHeld = Lock(true)
      self.database = database
      self.transport = try ipcTransport(directory)
      self.subscription = try self.transport.subscribe(to: database, region: region) { message in
        recorder.append(message)
        let holds = isHeld.withLock { isHeld in
          defer { isHeld = false }
          return isHeld
        }
        if holds { gate.blockingWait() }
      }
    }

    deinit {
      // A test that fails before resuming must not leave the transport's thread held for good.
      self.gate.signal()
    }

    func resume() { self.gate.signal() }

    /// Holds the receiver in its handler at a first commit from `sender`, before its queue fills,
    /// so its thread frees no room afterwards, then sends it commits, each to a column of its own,
    /// until `sender` owes it one.
    ///
    /// - Returns: The commits its queue holds, the first included, and the region of the one
    ///   `sender` owes it.
    func fill(
      from sender: UnixDatagramIPCTransport
    ) async throws -> (queued: [OrbitIPCMessage], owed: OrbitDatabaseRegion) {
      var queued = [columnCommit(self.database, 0)]
      try await sender.send(queued[0])
      try await self.recorder.waitForCount(1)
      while sender.owedRegions.isEmpty {
        guard queued.count <= 10_000 else { throw TestTimeout() }
        queued.append(columnCommit(self.database, queued.count))
        try await sender.send(queued[queued.count - 1])
      }
      return (Array(queued.dropLast()), itemsColumn(queued.count - 1))
    }
  }
#endif
