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
    func transactionObserverRegionFiltersSiblingsAndPeersUntilItWidens() async throws {
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
      #expect(observer.commits.isEmpty)
      #expect(receivingTransport.advertisedRegion(for: identifier) == items)

      try subscription.updateRegion(items.union(lists))
      try await siblingDatabase.write { $0.notifyChanges(in: lists) }
      try await peerTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier, region: lists))
      )

      #expect(
        observer.commits == [
          OrbitDatabaseCommit(origin: .local, region: lists),
          OrbitDatabaseCommit(origin: .external, region: lists)
        ]
      )
      #expect(receivingTransport.advertisedRegion(for: identifier) == items.union(lists))
      #expect(subscription.region == items.union(lists))
    }

    @Test
    func ownTransactionsAreReportedWhateverTheRegion() async throws {
      let database = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: .unique(),
        transport: InMemoryIPCTransport()
      )
      let observer = CommitRecorder()
      let subscription = try database.subscribe(transactionObserver: observer, region: items)

      try await database.write { $0.notifyChanges(in: lists) }

      #expect(observer.commits == [OrbitDatabaseCommit(origin: .local, region: lists)])
      _ = subscription
    }

    @Test
    func valueObservationIsNotToldAboutPeerCommitsOutsideWhatItReads() async throws {
      try await withPeerDatabases { peers in
        let recorder = ValueRecorder<Int>()
        let subscription = try OrbitValueObservation<Int>
          .tracking { transaction in
            try transaction.fetchOne(#sql("SELECT COUNT(*) FROM a", as: Int.self)) ?? 0
          }
          .removeDuplicates()
          .subscribe(
            to: peers.observing,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForValue(1)
        let advertised = try #require(
          peers.observingTransport.base.advertisedRegion(for: peers.identifier)
        )
        #expect(advertised.overlaps(OrbitDatabaseRegion(table: "a")))
        #expect(!advertised.overlaps(OrbitDatabaseRegion(table: "b")))

        try await peers.writing.write { try $0.execute("INSERT INTO b DEFAULT VALUES") }
        #expect(peers.observingTransport.messages.isEmpty)

        try await peers.writing.write { try $0.execute("INSERT INTO a (flag) VALUES (0)") }
        try await recorder.waitForValue(2)

        #expect(peers.observingTransport.messages.count == 1)
        #expect(recorder.values == [1, 2])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }
    }

    @Test
    func valueObservationSeesPeerCommitsToWhatItStartsReading() async throws {
      try await withPeerDatabases { peers in
        let recorder = ValueRecorder<Int?>()
        let subscription = try flaggedCountObservation()
          .subscribe(
            to: peers.observing,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForValue(nil)

        try await peers.writing.write { try $0.execute("INSERT INTO b DEFAULT VALUES") }
        #expect(peers.observingTransport.messages.isEmpty)

        try await peers.writing.write { try $0.execute("UPDATE a SET flag = 1") }
        try await recorder.waitForValue(1)
        #expect(
          peers.observingTransport.base.advertisedRegion(for: peers.identifier)?
            .overlaps(OrbitDatabaseRegion(table: "b")) == true
        )

        try await peers.writing.write { try $0.execute("INSERT INTO b DEFAULT VALUES") }
        try await recorder.waitForValue(2)

        #expect(recorder.values == [nil, 1, 2])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }
    }

    @Test
    func valueObservationFetchesAgainForACommitThatLandsWhileItsRegionWidens() async throws {
      try await withPeerDatabases { peers in
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

    @Test
    func localCommitIsFollowedByAFetchForCommitsThatLandWhileItsRegionWidens() async throws {
      try await withPeerDatabases { peers in
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

    @Test
    func failingToWidenTheRegionEndsTheObservation() async throws {
      try await withPeerDatabases { peers in
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

    /// Opens one database file as two coordinating processes would, each with its own writer and
    /// transport on one network, along with a connection whose writes are never announced.
    private func withPeerDatabases(_ body: (Peers) async throws -> Void) async throws {
      let directory = try makeShortTemporaryDirectory("regions")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))
      let identifier = OrbitDatabaseIdentifier.unique()
      let network = InMemoryIPCTransport.Network()
      let observingTransport = RecordingIPCTransport(InMemoryIPCTransport(network: network))
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
        transport: InMemoryIPCTransport(network: network)
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

  private struct RegionUpdateFailure: Error {}

  /// Forwards to an in-memory transport, recording what its handlers receive and running a hook
  /// before each region update reaches it.
  private final class RecordingIPCTransport: OrbitIPCTransport, Sendable {
    let base: InMemoryIPCTransport
    private let received = Lock([OrbitIPCMessage]())
    private let hook = Lock<(@Sendable (OrbitDatabaseRegion) throws -> Bool)?>(nil)

    var messages: [OrbitIPCMessage] { received.withLock { $0 } }

    init(_ base: InMemoryIPCTransport) {
      self.base = base
    }

    /// Runs `hook` before region updates until it returns `true` once.
    func beforeRegionUpdate(_ hook: @escaping @Sendable (OrbitDatabaseRegion) throws -> Bool) {
      self.hook.withLock { $0 = hook }
    }

    func subscribe(
      to databaseIdentifier: OrbitDatabaseIdentifier,
      onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
    ) throws -> OrbitSubscription {
      try base.subscribe(to: databaseIdentifier) { [self] message in
        record(message)
        onMessage(message)
      }
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
