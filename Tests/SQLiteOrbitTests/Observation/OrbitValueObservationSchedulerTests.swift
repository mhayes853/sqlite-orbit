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
    let didRun = TestCounter()

    scheduler.schedule(from: nil) {
      destination.assumeIsolated { _ in
        _ = didRun.increment()
      }
    }

    try await didRun.waitForCount(1)
  }

  @Test
  func asyncSchedulerPreservesSubmissionOrder() async throws {
    let scheduler = OrbitAsyncValueObservationScheduler.async(on: Destination())
    let values = TestRecorder<Int>()

    for value in 0..<100 {
      scheduler.schedule(from: nil) {
        values.append(value)
      }
    }

    try await values.waitForCount(100)
    #expect(values.values == Array(0..<100))
  }

  @MainActor
  @Test
  func asyncSchedulerRunsInlineWhenIsolationMatches() {
    let scheduler = OrbitAsyncValueObservationScheduler.async(on: MainActor.shared)
    let didRun = TestCounter()

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: MainActor.shared)
    #expect(hasImmediateInitialValue)
    scheduler.schedule(from: MainActor.shared) {
      didRun.increment()
    }

    #expect(didRun.value == 1)
  }

  @MainActor
  @Test(arguments: MainActorScheduler.allCases)
  func aSchedulerDoesNotRunAnInlineCallbackAheadOfQueuedOnes(
    _ kind: MainActorScheduler
  ) async throws {
    let scheduler = kind.scheduler
    let values = TestRecorder<Int>()

    // Nothing here suspends, so the task draining the queued callback cannot reach the main actor
    // before the inline one is scheduled.
    scheduler.schedule(from: nil) { values.append(1) }
    scheduler.schedule(from: MainActor.shared) { values.append(2) }

    try await values.waitForCount(2)
    #expect(values.values == [1, 2])
  }

  @Test
  func asyncSchedulerWithoutAnActorDefersItsInitialValue() {
    let scheduler = OrbitAsyncValueObservationScheduler.async()

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: nil)

    #expect(!hasImmediateInitialValue)
  }
}
