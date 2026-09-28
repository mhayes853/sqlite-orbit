import Testing

@testable import SQLiteOrbit

@Suite
struct OrbitValueObservationSchedulerTests {
  private actor Destination {}

  /// The schedulers that run their callbacks on the main actor.
  enum MainActorScheduler: CaseIterable, Sendable {
    case async, mainActor

    var scheduler: any OrbitValueObservationScheduler {
      switch self {
      case .async: OrbitAsyncValueObservationScheduler.async(on: MainActor.shared)
      case .mainActor: OrbitMainActorValueObservationScheduler.mainActor
      }
    }
  }

  @Test
  func asyncSchedulerRunsOnItsActor() async throws {
    let destination = Destination()
    let scheduler = OrbitAsyncValueObservationScheduler.async(on: destination)
    let didRun = Lock(false)

    scheduler.schedule(from: nil) {
      destination.assumeIsolated { _ in
        didRun.withLock { $0 = true }
      }
    }

    try await waitUntil { didRun.withLock { $0 } }
  }

  @Test
  func asyncSchedulerPreservesSubmissionOrder() async throws {
    let scheduler = OrbitAsyncValueObservationScheduler.async(on: Destination())
    let values = Lock([Int]())

    for value in 0..<100 {
      scheduler.schedule(from: nil) {
        values.withLock { $0.append(value) }
      }
    }

    try await waitUntil { values.withLock { $0.count == 100 } }
    #expect(values.withLock { $0 } == Array(0..<100))
  }

  @MainActor
  @Test
  func asyncSchedulerRunsInlineWhenIsolationMatches() {
    let scheduler = OrbitAsyncValueObservationScheduler.async(on: MainActor.shared)
    let didRun = Lock(false)

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: MainActor.shared)
    #expect(hasImmediateInitialValue)
    scheduler.schedule(from: MainActor.shared) {
      didRun.withLock { $0 = true }
    }

    #expect(didRun.withLock { $0 })
  }

  @MainActor
  @Test(arguments: MainActorScheduler.allCases)
  func aSchedulerDoesNotRunAnInlineCallbackAheadOfQueuedOnes(
    _ kind: MainActorScheduler
  ) async throws {
    let scheduler = kind.scheduler
    let values = Lock([Int]())

    // Nothing here suspends, so the task draining the queued callback cannot reach the main actor
    // before the inline one is scheduled.
    scheduler.schedule(from: nil) { values.withLock { $0.append(1) } }
    scheduler.schedule(from: MainActor.shared) { values.withLock { $0.append(2) } }

    try await waitUntil { values.withLock { $0.count == 2 } }
    #expect(values.withLock { $0 } == [1, 2])
  }

  @Test
  func asyncSchedulerWithoutAnActorDefersItsInitialValue() {
    let scheduler = OrbitAsyncValueObservationScheduler.async()

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: nil)

    #expect(!hasImmediateInitialValue)
  }
}
