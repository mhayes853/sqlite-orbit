import Synchronization
import Testing

@testable import SQLiteOrbit

@Suite
struct ValueObservationSchedulerTests {
  private actor Destination {}

  @Test
  func immediateSchedulerRunsInlineWithoutIsolation() {
    let scheduler = ImmediateValueObservationScheduler.immediate
    let didRun = Mutex(false)

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: nil)
    #expect(hasImmediateInitialValue)
    scheduler.schedule(from: nil) {
      didRun.withLock { $0 = true }
    }

    #expect(didRun.withLock { $0 })
  }

  @Test
  func asyncSchedulerRunsOnItsActor() async throws {
    let destination = Destination()
    let scheduler = AsyncValueObservationScheduler.async(on: destination)
    let didRun = Mutex(false)

    scheduler.schedule(from: nil) {
      destination.assumeIsolated { _ in
        didRun.withLock { $0 = true }
      }
    }

    try await waitUntil { didRun.withLock { $0 } }
  }

  @Test
  func asyncSchedulerPreservesSubmissionOrder() async throws {
    let scheduler = AsyncValueObservationScheduler.async(on: Destination())
    let values = Mutex([Int]())

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
    let scheduler = AsyncValueObservationScheduler.async(on: MainActor.shared)
    let didRun = Mutex(false)

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: MainActor.shared)
    #expect(hasImmediateInitialValue)
    scheduler.schedule(from: MainActor.shared) {
      didRun.withLock { $0 = true }
    }

    #expect(didRun.withLock { $0 })
  }

  @Test
  func asyncSchedulerWithoutAnActorDefersItsInitialValue() {
    let scheduler = AsyncValueObservationScheduler.async()

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: nil)

    #expect(!hasImmediateInitialValue)
  }

  @MainActor
  @Test
  func mainActorSchedulerIsImmediateOnlyWhenAlreadyIsolated() {
    let scheduler = MainActorValueObservationScheduler.mainActor
    requireMainActorScheduler(scheduler)

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: MainActor.shared)
    #expect(hasImmediateInitialValue)
  }

  @Test
  func mainActorSchedulerIsNotImmediateOutsideMainActor() {
    let scheduler = MainActorValueObservationScheduler.mainActor

    let hasImmediateInitialValue = scheduler.immediateInitialValue(from: nil)
    #expect(!hasImmediateInitialValue)
  }

  private func requireMainActorScheduler<Scheduler: ValueObservationMainActorScheduler>(
    _ scheduler: Scheduler
  ) {}
}
