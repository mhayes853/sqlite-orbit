#if BuiltInSQLite
  import SQLiteOrbit
  import Testing

  @Suite
  struct OrbitFetchSubscriptionTests {
    @Test(arguments: [false, true])
    func cancellationAndReplacementFinishCopiesAndLateWaiters(replacing: Bool) async throws {
      let database = try await itemsDatabase()
      let property = Fetch(wrappedValue: -1)
      let subscription = try await property.load(counts, database: database)
      let copy = subscription
      let started = TestCounter()
      let finished = TestCounter()
      let waiters = [subscription, copy]
        .map { token in
          Task {
            started.increment()
            try await token.waitUntilFinished()
            finished.increment()
          }
        }
      defer { for waiter in waiters { waiter.cancel() } }
      try await started.waitForCount(2)
      #expect(finished.value == 0)
      if replacing {
        // Discarding a token leaves the property's new observation running.
        _ = try await property.load(counts.map { $0 + 10 }, database: database)
      } else {
        copy.cancel()
      }
      try await finished.waitForCount(2)
      for waiter in waiters { try await waiter.value }
      try await subscription.waitUntilFinished()
      subscription.cancel()
      try await insertItems(1, into: database)
      #expect(property.wrappedValue == (replacing ? 11 : 0))

      if replacing {
        let cancelled = Task {
          withUnsafeCurrentTask { $0?.cancel() }
          try await subscription.waitUntilFinished()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await insertItems(2, into: database)
        #expect(property.wrappedValue == 12)
      }
    }

    @Test
    func observationFailureIsSharedAndRemainsTheLoadError() async throws {
      final class Failure: Error, Sendable {}
      let failure = Failure()
      let database = try await itemsDatabase()
      let property = Fetch(wrappedValue: -1)
      let observation = counts.map { value in
        if value > 0 { throw failure }
        return value
      }
      let subscription = try await property.load(observation, database: database)
      let finished = TestCounter()
      let waiter = Task {
        defer { finished.increment() }
        do {
          try await subscription.waitUntilFinished()
          return nil as (any Error)?
        } catch {
          return error
        }
      }
      defer { waiter.cancel() }
      try await insertItems(1, into: database)
      try await finished.waitForCount(1)
      let error = await waiter.value
      #expect((error as? Failure) === failure)
      #expect((property.loadError as? Failure) === failure)
      #expect(property.wrappedValue == 0)
      do {
        try await subscription.waitUntilFinished()
        Issue.record("A late waiter did not receive the observation error")
      } catch {
        #expect((error as? Failure) === failure)
      }
    }

    @Test(arguments: [false, true])
    func cancellingAWaitingTaskStopsTheRegistrationAndFinishesOtherWaiters(alreadyCancelled: Bool)
      async throws
    {
      let database = try await itemsDatabase()
      let property = Fetch(wrappedValue: -1)
      let subscription = try await property.load(counts, database: database)
      let started = TestCounter()
      let otherFinished = TestCounter()
      let other = Task {
        started.increment()
        try await subscription.waitUntilFinished()
        otherFinished.increment()
      }
      defer { other.cancel() }
      let cancelled = Task {
        if alreadyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
        started.increment()
        try await subscription.waitUntilFinished()
      }
      defer { cancelled.cancel() }
      try await started.waitForCount(2)
      if !alreadyCancelled { cancelled.cancel() }
      try await otherFinished.waitForCount(1)
      await #expect(throws: CancellationError.self) { try await cancelled.value }
      try await other.value
      try await subscription.waitUntilFinished()
      try await insertItems(1, into: database)
      #expect(property.wrappedValue == 0)
    }

    @Test
    func anObservableReaderCanSupplyFetchesExplicitly() async throws {
      let database = try await itemsDatabase()
      let reader = ReaderOnlyObservationDatabase(database)
      let registration = try reader.subscribe(transactionObserver: NoopObserver())
      defer { registration.cancel() }
      #expect(!registration.filtersByRegion)
      let filtered = OrbitRegionSubscription(
        region: .empty,
        onUpdateRegion: { _ in },
        onCancel: {}
      )
      #expect(filtered.filtersByRegion)

      let property = Fetch(wrappedValue: -1, counts, database: reader)
      #expect(property.wrappedValue == 0)
      try await insertItems(1, into: database)
      #expect(property.wrappedValue == 1)
    }

    private var counts: OrbitValueObservation<Int> {
      .tracking { transaction in
        try transaction.fetchOne(itemCountSQL) { Int($0[0].integerValue ?? 0) } ?? 0
      }
    }

    private struct NoopObserver: OrbitDatabaseTransactionObserver {}
  }

  final class ReaderOnlyObservationDatabase: OrbitObservableDatabase {
    private let base: SQLiteQueue

    init(_ base: SQLiteQueue) { self.base = base }

    func subscribe(
      transactionObserver: any OrbitDatabaseTransactionObserver,
      region: OrbitDatabaseRegion
    ) throws -> OrbitRegionSubscription {
      try base.subscribe(transactionObserver: transactionObserver, region: region)
    }

    func read<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) async throws -> Result { try await base.read(body) }

    func readBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) throws -> Result { try base.readBlocking(body) }

    func readWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) async throws -> Result { try await base.readWithoutTransaction(body) }

    func readWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) throws -> Result { try base.readWithoutTransactionBlocking(body) }
  }
#endif
