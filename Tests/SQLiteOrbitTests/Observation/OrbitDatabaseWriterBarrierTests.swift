#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Suite
  struct OrbitDatabaseWriterBarrierTests {
    @Test
    func aCustomDatabaseCoordinatesRefetchesUsingOnlyPublicAPIs() async throws {
      let database = AnnouncingTestDatabase(try await itemsDatabase())
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
      try await insertItems(1, into: database)
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
      try await insertItems(2, into: database)
      try await waitUntil { later.waitCount == 1 }
      #expect(fetches.value == 2)
      later.complete()
      try await values.waitForCount(3)
      #expect(values.values == [0, 1, 2])
      #expect(fetches.value == 3)

      // Without an active cohort, coalesced refetching can proceed immediately.
      database.setActiveWriters(nil)
      try await insertItems(3, into: database)
      try await values.waitForCount(4)
      #expect(values.values == [0, 1, 2, 3])
      #expect(fetches.value == 4)
    }
  }

  // This custom barrier and the shared AnnouncingTestDatabase use only public library APIs.
  // The asynchronous wait state belongs to the test, independently of native pool internals.
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

#endif
