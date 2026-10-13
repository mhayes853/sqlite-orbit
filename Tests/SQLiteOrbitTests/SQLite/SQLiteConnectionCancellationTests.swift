import Testing

@testable import SQLiteOrbit

@Suite
struct SQLiteConnectionCancellationTests {
  @Test
  func cancellationBeforeStartingRunsNeitherTheAccessNorItsInterrupt() {
    let cancellation = SQLiteConnectionCancellation()
    let accesses = TestCounter()
    let interrupts = TestCounter()
    let interrupt: @Sendable () -> Void = { interrupts.increment() }
    cancellation.cancel()
    cancellation.cancel()

    #expect(throws: CancellationError.self) {
      try cancellation.withInterruption(interrupt: interrupt) {
        accesses.increment()
      }
    }
    #expect(accesses.value == 0)
    #expect(interrupts.value == 0)
  }

  @Test
  func repeatedCancellationInterruptsAnAccessOnlyOnce() throws {
    let cancellation = SQLiteConnectionCancellation()
    let interrupts = TestCounter()
    let interrupt: @Sendable () -> Void = { interrupts.increment() }

    #expect(throws: CancellationError.self) {
      try cancellation.withInterruption(interrupt: interrupt) {
        cancellation.cancel()
        cancellation.cancel()
        #expect(interrupts.value == 1)
        throw SQLiteError(code: .interrupt)
      }
    }
    cancellation.cancel()
    #expect(interrupts.value == 1)
  }

  @Test
  func cancellationAfterCompletionDoesNotInterruptLaterWork() throws {
    let cancellation = SQLiteConnectionCancellation()
    let interrupts = TestCounter()
    let interrupt: @Sendable () -> Void = { interrupts.increment() }

    let result = try cancellation.withInterruption(interrupt: interrupt) { 42 }
    cancellation.cancel()
    cancellation.cancel()

    #expect(result == 42)
    #expect(interrupts.value == 0)
  }

  @Test
  func aThrowingAccessDisarmsItsInterruptAndPreservesItsError() {
    let cancellation = SQLiteConnectionCancellation()
    let interrupts = TestCounter()
    let interrupt: @Sendable () -> Void = { interrupts.increment() }

    #expect(throws: TestError("access failed")) {
      try cancellation.withInterruption(interrupt: interrupt) {
        throw TestError("access failed")
      }
    }
    cancellation.cancel()
    #expect(interrupts.value == 0)
  }

  @Test
  func anInterruptionWithoutTokenCancellationPreservesItsSQLiteError() {
    let cancellation = SQLiteConnectionCancellation()
    let interruption = SQLiteError(code: .interrupt, message: "interrupted elsewhere")
    let interrupt: @Sendable () -> Void = {}

    #expect(throws: interruption) {
      try cancellation.withInterruption(interrupt: interrupt) {
        throw interruption
      }
    }
  }

  @Test(arguments: [false, true])
  func anAccessReleasesItsInterruptCaptureWhetherItReturnsOrThrows(_ shouldThrow: Bool) {
    let cancellation = SQLiteConnectionCancellation()
    let releases = TestCounter()

    do {
      let capture = InterruptCapture(releases: releases)
      try cancellation.withInterruption(interrupt: capture.interrupt) {
        if shouldThrow { throw TestError() }
      }
    } catch {
      #expect(shouldThrow)
      #expect(error as? TestError == TestError())
    }
    #expect(releases.value == 1)
    cancellation.cancel()
    #expect(releases.value == 1)
  }

  #if !os(WASI)
    @Test
    func cancellationFromAnotherThreadInterruptsAnActiveAccess() async throws {
      let cancellation = SQLiteConnectionCancellation()
      let interrupts = TestCounter()
      let interrupt: @Sendable () -> Void = { interrupts.increment() }
      let body = TestGate()
      defer { body.open() }

      let access = Task {
        try await withDeadline {
          try cancellation.withInterruption(interrupt: interrupt) {
            try body.enter()
            throw SQLiteError(code: .interrupt)
          }
        }
      }
      try await body.waitUntilEntered()
      cancellation.cancel()
      #expect(interrupts.value == 1)
      body.open()
      await #expect(throws: CancellationError.self) { try await access.value }
    }

    @Test
    func anAccessCannotFinishBeforeItsInFlightInterruptHasBeenDelivered() async throws {
      let cancellation = SQLiteConnectionCancellation()
      let body = TestGate()
      let interrupt = TestGate()
      let bodyFinished = TestCounter()
      let accessFinished = TestCounter()
      let onInterrupt: @Sendable () -> Void = { try? interrupt.enter() }
      defer {
        body.open()
        interrupt.open()
      }

      let access = Task {
        try await withDeadline {
          try cancellation.withInterruption(interrupt: onInterrupt) {
            try body.enter()
            bodyFinished.increment()
          }
          accessFinished.increment()
        }
      }
      try await body.waitUntilEntered()
      let cancel = Task { try await withDeadline { cancellation.cancel() } }
      try await interrupt.waitUntilEntered()
      body.open()
      try await bodyFinished.waitForCount(1)
      // Let the access reach its deferred disarm while the interrupt's thread is still blocked.
      for _ in 0..<5000 { await Task.yield() }
      #expect(accessFinished.value == 0)

      interrupt.open()
      try await cancel.value
      try await access.value
      #expect(accessFinished.value == 1)
    }
  #endif
}

private final class InterruptCapture: Sendable {
  let releases: TestCounter

  init(releases: TestCounter) {
    self.releases = releases
  }

  func interrupt() {}

  deinit {
    releases.increment()
  }
}
