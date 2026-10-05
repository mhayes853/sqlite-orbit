#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Suite
  struct OrbitDatabaseWriterBarrierTests {
    @Test
    func aCustomDatabaseCoordinatesRefetchesUsingOnlyPublicAPIs() async throws {
      let queue = try SQLiteQueue(path: ":memory:")
      try await queue.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let database = PublicBarrierDatabase(queue)
      let values = TestRecorder<Int64>()
      let fetches = TestCounter()
      let subscription = try OrbitValueObservation<Int64>
        .tracking(region: OrbitDatabaseRegion(table: "items")) { transaction in
          fetches.increment()
          return try transaction.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue ?? 0 }
            ?? 0
        }
        .refetching(.coalesced)
        .subscribe(
          to: database,
          onError: { Issue.record("Unexpected observation error: \($0)") },
          onChange: { values.append($0.value) }
        )
      defer { subscription.cancel() }
      try await values.waitForCount(1)

      let first = PublicObservationBarrier()
      let later = PublicObservationBarrier()
      defer {
        first.complete()
        later.complete()
      }
      database.setActiveWriters(first)
      try await database.write { transaction in
        try transaction.execute("INSERT INTO items VALUES (1)")
      }
      // Changing the provider after commit delivery cannot extend the captured cohort.
      database.setActiveWriters(later)
      try await waitUntil { first.waitCount == 1 }
      #expect(fetches.value == 1)
      #expect(values.values == [0])

      first.complete()
      try await values.waitForCount(2)
      #expect(values.values == [0, 1])
      #expect(later.hasActiveWriters)
      #expect(later.waitCount == 0)

      // A subsequent commit captures the new cohort independently.
      try await database.write { transaction in
        try transaction.execute("INSERT INTO items VALUES (2)")
      }
      try await waitUntil { later.waitCount == 1 }
      #expect(fetches.value == 2)
      later.complete()
      try await values.waitForCount(3)
      #expect(values.values == [0, 1, 2])
      #expect(fetches.value == 3)
    }

    @Test
    func aSerialDatabaseNeedsNoWriterBarrier() throws {
      let queue = try SQLiteQueue(path: ":memory:")
      #expect(queue.captureActiveWriters() == nil)
    }
  }

  // The provider, barrier, and observer adapter below compile against an ordinary public import.
  // Their synchronization storage belongs to the test, independently of native pool internals.
  private final class PublicObservationBarrier: OrbitDatabaseWriterBarrier, @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private var waits = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var hasActiveWriters: Bool { lock.withLock { isActive } }
    var waitCount: Int { lock.withLock { waits } }

    func wait() async {
      await withCheckedContinuation { continuation in
        let isComplete = lock.withLock {
          waits += 1
          guard isActive else { return true }
          continuations.append(continuation)
          return false
        }
        if isComplete { continuation.resume() }
      }
    }

    func complete() {
      let waiting = lock.withLock {
        isActive = false
        defer { continuations.removeAll() }
        return continuations
      }
      for continuation in waiting { continuation.resume() }
    }
  }

  private final class PublicBarrierDatabase: OrbitObservableDatabase, @unchecked Sendable {
    private let base: SQLiteQueue
    private let lock = NSLock()
    private var activeWriters: (any OrbitDatabaseWriterBarrier)?

    init(_ base: SQLiteQueue) { self.base = base }

    func setActiveWriters(_ barrier: (any OrbitDatabaseWriterBarrier)?) {
      lock.withLock { activeWriters = barrier }
    }

    func captureActiveWriters() -> (any OrbitDatabaseWriterBarrier)? {
      lock.withLock { activeWriters }
    }

    func subscribe(
      transactionObserver: any OrbitDatabaseTransactionObserver,
      region: OrbitDatabaseRegion
    ) throws -> OrbitRegionSubscription {
      try base.subscribe(
        transactionObserver: AfterCommitObserver(transactionObserver),
        region: region
      )
    }

    func read<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) async throws -> Result {
      try await base.read(body)
    }

    func readBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) throws -> Result {
      try base.readBlocking(body)
    }

    func readWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) async throws -> Result {
      try await base.readWithoutTransaction(body)
    }

    func readWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) throws -> Result {
      try base.readWithoutTransactionBlocking(body)
    }

    func write<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) async throws -> Result {
      try await base.write(body)
    }

    func writeBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result {
      try base.writeBlocking(body)
    }

    func writeWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) async throws -> Result {
      try await base.writeWithoutTransaction(body)
    }

    func writeWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) throws -> Result {
      try base.writeWithoutTransactionBlocking(body)
    }
  }

  private struct AfterCommitObserver: OrbitDatabaseTransactionObserver {
    let base: any OrbitDatabaseTransactionObserver

    init(_ base: any OrbitDatabaseTransactionObserver) { self.base = base }

    // Omitting will-commit forces observation to fetch after the fact, as concurrent drivers do.
    func databaseDidCommit(_ commit: OrbitDatabaseCommit) { base.databaseDidCommit(commit) }
  }
#endif
