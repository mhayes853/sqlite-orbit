#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Suite
  struct OrbitCompositeDatabaseTransactionObserverTests {
    private let items = OrbitDatabaseRegion(table: "items")

    @Test
    func forwardsEveryCallbackToEveryMemberWhateverItsRegion() {
      let composite = OrbitCompositeDatabaseTransactionObserver()
      let first = TransactionEventRecorder()
      let second = TransactionEventRecorder()
      let firstSubscription = composite.subscribe(first)
      let secondSubscription = composite.subscribe(
        second,
        region: OrbitDatabaseRegion(table: "elsewhere")
      )

      composite.databaseDidRead(in: items)
      composite.databaseDidChange(in: items)
      composite.databaseDidCommit(OrbitDatabaseCommit(origin: .external, region: items))
      composite.databaseDidRollback()

      for recorder in [first, second] {
        #expect(recorder.readRegions == [items])
        #expect(recorder.events == [.didChange(items), .didCommit(.external), .didRollback])
      }
      #expect(firstSubscription.region == .fullDatabase)
      #expect(secondSubscription.region == OrbitDatabaseRegion(table: "elsewhere"))
    }

    @Test
    func emptyRegionsAreNotForwarded() {
      let composite = OrbitCompositeDatabaseTransactionObserver()
      let recorder = TransactionEventRecorder()
      let subscription = composite.subscribe(recorder)
      defer { subscription.cancel() }

      composite.databaseDidRead(in: OrbitDatabaseRegion())
      composite.databaseDidChange(in: OrbitDatabaseRegion())

      #expect(recorder.readRegions.isEmpty)
      #expect(recorder.events.isEmpty)
    }

    @Test
    func aCancelledOrReleasedSubscriptionStopsForwarding() {
      let composite = OrbitCompositeDatabaseTransactionObserver()
      let cancelled = TransactionEventRecorder()
      let released = TransactionEventRecorder()
      let subscription = composite.subscribe(cancelled)
      do {
        _ = composite.subscribe(released)
      }
      subscription.cancel()

      composite.databaseDidCommit(OrbitDatabaseCommit(origin: .local))

      #expect(cancelled.events.isEmpty)
      #expect(released.events.isEmpty)
    }

    @Test
    func aMemberRejectingTheCommitRollsTheTransactionBackForEveryMember() async throws {
      let connection = try SQLiteSerialConnection(
        path: .memory,
        configuration: .default,
        setups: [.sql("CREATE TABLE items (id INTEGER PRIMARY KEY)")]
      )
      let composite = OrbitCompositeDatabaseTransactionObserver()
      let rejecting = TransactionEventRecorder(commitError: Rejection())
      let watching = TransactionEventRecorder()
      let subscriptions = [composite.subscribe(rejecting), composite.subscribe(watching)]
      defer { for subscription in subscriptions { subscription.cancel() } }

      await #expect(throws: Rejection.self) {
        try await connection.withWriteConnection { connection in
          try connection.transaction(observer: composite) { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (1)")
          }
        }
      }

      for recorder in [rejecting, watching] {
        #expect(recorder.events.last == .didRollback)
        #expect(!recorder.events.contains(.didCommit(.local)))
      }
      let count = try await connection.withReadConnection { connection in
        try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
      }
      #expect(count == 0)
    }
  }

  private struct Rejection: Error {}
#endif
