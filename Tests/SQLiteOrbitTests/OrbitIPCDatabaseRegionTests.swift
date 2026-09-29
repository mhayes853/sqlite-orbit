#if BuiltInSQLite
  import Foundation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct OrbitIPCDatabaseRegionTests {
    private let items = OrbitDatabaseRegion(table: "items")
    private let lists = OrbitDatabaseRegion(table: "lists")

    @Test
    func transactionObserverRegionFiltersOnlySiblingsAndPeers() async throws {
      let identifier = OrbitDatabaseIdentifier.unique()
      let network = InMemoryIPCTransport.Network()
      let receivingTransport = InMemoryIPCTransport(network: network)
      let peerTransport = InMemoryIPCTransport(network: network)
      let observingDatabase = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: receivingTransport
      )
      let siblingDatabase = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: InMemoryIPCTransport()
      )
      let observer = CommitRecorder()
      let subscription = try observingDatabase.subscribe(
        transactionObserver: observer,
        region: items
      )

      try await siblingDatabase.write { $0.notifyChanges(in: lists) }
      try await peerTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier, region: lists))
      )
      let commitsBeforeWidening = observer.commits
      let advertisedBeforeWidening = receivingTransport.advertisedRegion(for: identifier)

      try subscription.updateRegion(items.union(lists))
      try await siblingDatabase.write { $0.notifyChanges(in: lists) }
      try await peerTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier, region: lists))
      )
      // The observed handle's own transactions are reported whatever the region.
      try subscription.updateRegion(items)
      try await observingDatabase.write { $0.notifyChanges(in: lists) }

      #expect(commitsBeforeWidening.isEmpty)
      #expect(advertisedBeforeWidening == items)
      #expect(
        observer.commits == [
          OrbitDatabaseCommit(origin: .local, region: lists),
          OrbitDatabaseCommit(origin: .external, region: lists),
          OrbitDatabaseCommit(origin: .local, region: lists)
        ]
      )
      #expect(subscription.region == items)
    }

    @Test(arguments: PeerTransport.allCases)
    func valueObservationIsToldOnlyAboutPeerCommitsToWhatItReads(transport: PeerTransport)
      async throws
    {
      try await withPeerDatabases(transport) { peers in
        let recorder = ValueRecorder<Int?>()
        let subscription = try flaggedCountObservation()
          .subscribe(
            to: peers.observing,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForValue(nil)
        let advertisedBeforeFlag = peers.observingTransport.advertisedRegion(for: peers.identifier)

        try await peers.writing.write { try $0.execute("INSERT INTO b DEFAULT VALUES") }
        try await peers.writing.write { try $0.execute("UPDATE a SET flag = 1") }
        try await recorder.waitForValue(1)
        // A transport that delivers asynchronously can report the commit to `a` after the sibling
        // database in this process already has. Either way, the commit to `b` was sent first, so
        // it would have arrived first.
        try await waitUntil(timeout: .seconds(5)) { !peers.observingTransport.messages.isEmpty }
        let messagesBeforeWidening = peers.observingTransport.messages.count
        let advertisedAfterFlag = peers.observingTransport.advertisedRegion(for: peers.identifier)

        try await peers.writing.write { try $0.execute("INSERT INTO b DEFAULT VALUES") }
        try await recorder.waitForValue(2)

        #expect(advertisedBeforeFlag?.overlaps(OrbitDatabaseRegion(table: "a")) == true)
        #expect(advertisedBeforeFlag?.overlaps(OrbitDatabaseRegion(table: "b")) == false)
        #expect(messagesBeforeWidening == 1)
        #expect(advertisedAfterFlag?.overlaps(OrbitDatabaseRegion(table: "b")) == true)
        #expect(recorder.values == [nil, 1, 2])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }
    }

    @Test(arguments: PeerTransport.allCases)
    func valueObservationFetchesAgainForACommitThatLandsWhileItsRegionWidens(
      transport: PeerTransport
    ) async throws {
      try await withPeerDatabases(transport) { peers in
        let recorder = ValueRecorder<Int?>()
        // Another process inserts into `b` after the fetch that first reads it, but before the
        // region covering `b` is advertised, so its announcement would have been skipped.
        peers.observingTransport.beforeRegionUpdate { region in
          guard region.overlaps(OrbitDatabaseRegion(table: "b")) else { return false }
          try peers.unannounced.writeBlocking { try $0.execute("INSERT INTO b DEFAULT VALUES") }
          return true
        }
        let subscription = try flaggedCountObservation()
          .subscribe(
            to: peers.observing,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForValue(nil)

        try await peers.writing.write { try $0.execute("UPDATE a SET flag = 1") }
        try await recorder.waitForValue(1)

        // The fetch that read `b` before its region was advertised is never published.
        #expect(recorder.values == [nil, 1])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }
    }

    @Test(arguments: PeerTransport.allCases)
    func localCommitIsFollowedByAFetchForCommitsThatLandWhileItsRegionWidens(
      transport: PeerTransport
    ) async throws {
      try await withPeerDatabases(transport) { peers in
        let recorder = ValueRecorder<Int?>()
        peers.observingTransport.beforeRegionUpdate { region in
          guard region.overlaps(OrbitDatabaseRegion(table: "b")) else { return false }
          try peers.unannounced.writeBlocking { try $0.execute("INSERT INTO b DEFAULT VALUES") }
          return true
        }
        let subscription = try flaggedCountObservation()
          .subscribe(
            to: peers.observing,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForValue(nil)

        // The fetch this commit makes inside its transaction is published at once, and the
        // insert that lands before `b` is advertised is picked up by the fetch that follows.
        try await peers.observing.write { try $0.execute("UPDATE a SET flag = 1") }
        try await recorder.waitForValue(1)

        #expect(recorder.values == [nil, 0, 1])
        #expect(recorder.sources == [.initial, .transaction(.local), .transaction(.external)])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }
    }

    @Test(arguments: PeerTransport.allCases)
    func failingToWidenTheRegionEndsTheObservation(transport: PeerTransport) async throws {
      try await withPeerDatabases(transport) { peers in
        let recorder = ValueRecorder<Int?>()
        peers.observingTransport.beforeRegionUpdate { region in
          guard region.overlaps(OrbitDatabaseRegion(table: "b")) else { return false }
          throw RegionUpdateFailure()
        }
        let subscription = try flaggedCountObservation()
          .subscribe(
            to: peers.observing,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForValue(nil)

        try await peers.writing.write { try $0.execute("UPDATE a SET flag = 1") }
        try await waitUntil(timeout: .seconds(5)) { !recorder.errors.isEmpty }

        #expect(recorder.errors == [String(describing: RegionUpdateFailure())])
        #expect(recorder.values == [nil])
        _ = subscription
      }
    }

    /// Counts the rows in `b`, but only reads `b` once the flag in `a` is set.
    private func flaggedCountObservation() -> OrbitValueObservation<Int?> {
      OrbitValueObservation<Int?>
        .tracking { transaction in
          let flag = try transaction.fetchOne(#sql("SELECT flag FROM a", as: Int.self)) ?? 0
          guard flag != 0 else { return nil }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM b", as: Int.self)) ?? 0
        }
        .removeDuplicates()
    }

    private struct Peers: Sendable {
      let identifier: OrbitDatabaseIdentifier
      let observing: OrbitIPCDatabase
      let observingTransport: RecordingIPCTransport
      let writing: OrbitIPCDatabase
      let unannounced: SQLiteQueue
    }

    /// The transports two peer databases coordinate through.
    enum PeerTransport: CaseIterable, Sendable {
      case inMemory
      #if canImport(Darwin) || os(Linux) || os(Android)
        case unixDatagram
      #endif

      /// Makes a pair of transports that are peers of each other.
      fileprivate func makePair(
        directory: URL
      ) throws -> (observing: RecordingIPCTransport, writing: any OrbitIPCTransport) {
        switch self {
        case .inMemory:
          let network = InMemoryIPCTransport.Network()
          let observing = InMemoryIPCTransport(network: network)
          return (
            RecordingIPCTransport(observing, advertisedRegion: observing.advertisedRegion(for:)),
            InMemoryIPCTransport(network: network)
          )
        #if canImport(Darwin) || os(Linux) || os(Android)
          case .unixDatagram:
            let configuration = UnixDatagramIPCTransport.Configuration(
              // Short, since the socket paths inside it must fit in `sun_path`.
              directory: directory.appending(path: "c")
            )
            let observing = try UnixDatagramIPCTransport(configuration: configuration)
            return (
              RecordingIPCTransport(observing, advertisedRegion: observing.advertisedRegion(for:)),
              try UnixDatagramIPCTransport(configuration: configuration)
            )
        #endif
        }
      }
    }

    /// Opens one database file as two coordinating processes would, each with its own writer and
    /// transport, the transports peers of each other, along with a connection whose writes are
    /// never announced.
    private func withPeerDatabases(
      _ transport: PeerTransport,
      _ body: (Peers) async throws -> Void
    ) async throws {
      try await withTemporaryDirectory("regions") { directory in
        let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))
        let identifier = OrbitDatabaseIdentifier.unique()
        let (observingTransport, writingTransport) = try transport.makePair(directory: directory)
        let observing = OrbitIPCDatabase(
          writer: try SQLiteQueue(path: path),
          id: identifier,
          transport: observingTransport
        )
        try await observing.write { transaction in
          try transaction.execute(
            """
            CREATE TABLE a (flag INTEGER NOT NULL);
            CREATE TABLE b (id INTEGER PRIMARY KEY);
            INSERT INTO a (flag) VALUES (0);
            """
          )
        }
        let writing = OrbitIPCDatabase(
          writer: try SQLiteQueue(path: path),
          id: identifier,
          transport: writingTransport
        )
        try await body(
          Peers(
            identifier: identifier,
            observing: observing,
            observingTransport: observingTransport,
            writing: writing,
            unannounced: try SQLiteQueue(path: path)
          )
        )
      }
    }
  }

  private struct RegionUpdateFailure: Error {}

  /// Forwards to another transport, recording what its handlers receive and running a hook
  /// before each region update reaches it.
  private final class RecordingIPCTransport: OrbitIPCTransport, Sendable {
    let base: any OrbitIPCTransport
    private let baseAdvertisedRegion: @Sendable (OrbitDatabaseIdentifier) -> OrbitDatabaseRegion?
    private let received = Lock([OrbitIPCMessage]())
    private let hook = Lock<(@Sendable (OrbitDatabaseRegion) throws -> Bool)?>(nil)

    var messages: [OrbitIPCMessage] { received.withLock { $0 } }

    init(
      _ base: any OrbitIPCTransport,
      advertisedRegion: @escaping @Sendable (OrbitDatabaseIdentifier) -> OrbitDatabaseRegion?
    ) {
      self.base = base
      self.baseAdvertisedRegion = advertisedRegion
    }

    /// The region the base transport advertises to its peers for a database.
    func advertisedRegion(for databaseIdentifier: OrbitDatabaseIdentifier) -> OrbitDatabaseRegion? {
      self.baseAdvertisedRegion(databaseIdentifier)
    }

    /// Runs `hook` before region updates until it returns `true` once.
    func beforeRegionUpdate(_ hook: @escaping @Sendable (OrbitDatabaseRegion) throws -> Bool) {
      self.hook.withLock { $0 = hook }
    }

    func subscribe(
      to databaseIdentifier: OrbitDatabaseIdentifier,
      region: OrbitDatabaseRegion,
      onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
    ) throws -> OrbitRegionSubscription {
      let subscription = try base.subscribe(to: databaseIdentifier, region: region) {
        [self] message in
        record(message)
        onMessage(message)
      }
      return OrbitRegionSubscription(region: region) { [self] region in
        try runHook(before: region)
        try subscription.updateRegion(region)
      } onCancel: {
        subscription.cancel()
      }
    }

    private func record(_ message: OrbitIPCMessage) {
      received.withLock { $0.append(message) }
    }

    private func runHook(before region: OrbitDatabaseRegion) throws {
      guard let action = hook.withLock({ $0 }), try action(region) else { return }
      hook.withLock { $0 = nil }
    }

    func send(_ message: OrbitIPCMessage) async throws {
      try await base.send(message)
    }
  }

  private final class CommitRecorder: OrbitDatabaseTransactionObserver, Sendable {
    private let recorded = Lock([OrbitDatabaseCommit]())

    var commits: [OrbitDatabaseCommit] { recorded.withLock { $0 } }

    func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
      recorded.withLock { $0.append(commit) }
    }
  }

  private final class ValueRecorder<Value: Sendable & Equatable>: Sendable {
    private struct State {
      var changes = [OrbitValueObservationChange<Value>]()
      var errors = [String]()
    }

    private let state = Lock(State())

    var values: [Value] { state.withLock { $0.changes.map(\.value) } }
    var sources: [OrbitValueObservationSource] { state.withLock { $0.changes.map(\.source) } }
    var errors: [String] { state.withLock { $0.errors } }

    func record(change: OrbitValueObservationChange<Value>) {
      state.withLock { $0.changes.append(change) }
    }

    func record(error: any Error) {
      state.withLock { $0.errors.append(String(describing: error)) }
    }

    func waitForValue(_ value: Value) async throws {
      try await waitUntil(timeout: .seconds(5)) { self.values.last == value }
    }
  }
#endif
