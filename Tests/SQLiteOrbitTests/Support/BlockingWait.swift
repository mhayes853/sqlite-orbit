import Dispatch

// `wait` is `noasync` on Apple platforms, which is a rule about blocking a thread the concurrency
// runtime is counting on. These tests block on purpose — they are about what a thread sees while
// another one holds something — and a synchronous function is where the compiler allows it.
extension DispatchSemaphore {
  /// Waits for the semaphore, blocking the calling thread.
  func blockingWait() {
    wait()
  }

  /// Waits for the semaphore until `timeout`, blocking the calling thread.
  ///
  /// - Parameter timeout: When to give up.
  /// - Returns: Whether the wait succeeded or timed out.
  func blockingWait(timeout: DispatchTime) -> DispatchTimeoutResult {
    wait(timeout: timeout)
  }
}
