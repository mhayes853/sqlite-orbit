/// A cancellation request for one synchronous SQLite connection access.
///
/// Create a token for each access, pass it to the connection, and call ``cancel()`` from another
/// thread when the access should stop. A token cancelled before its access begins prevents the
/// access from running. While the access is running, cancellation interrupts its SQLite work.
/// Cancelling after the access ends does nothing to the connection or its later accesses.
///
/// A token is used for exactly one access. Sharing it between accesses, including using it again
/// after an access ends, is a programming error.
public final class SQLiteConnectionCancellation: Sendable {
  private struct State {
    var hasStarted = false
    var isCancelled = false
    var interrupt: (@Sendable () -> Void)?
  }

  private let state = Lock(State())

  /// Creates a token for one connection access.
  public init() {}

  /// Requests cancellation, from any thread.
  ///
  /// Repeated requests have no further effect. SQLite work that has already finished may still
  /// return successfully; cancellation interrupts work in progress rather than undoing it.
  public func cancel() {
    state.withLock { state in
      guard !state.isCancelled else { return }
      state.isCancelled = true
      // Calling under the lock keeps the access's disarm from returning before the interrupt has
      // been delivered. Otherwise a delayed interrupt could reach the connection's next access.
      state.interrupt?()
    }
  }

  func withInterruption<Result: ~Copyable>(
    interrupt: @escaping @Sendable () -> Void,
    _ body: () throws -> Result
  ) throws -> Result {
    try state.withLock { state in
      precondition(
        !state.hasStarted,
        "A SQLiteConnectionCancellation token can only be used for one connection access."
      )
      state.hasStarted = true
      guard !state.isCancelled else { throw CancellationError() }
      state.interrupt = interrupt
    }
    defer { state.withLock { $0.interrupt = nil } }
    do {
      return try body()
    } catch let error as SQLiteError
      where error.isInterruption && state.withLock({ $0.isCancelled })
    {
      throw CancellationError()
    }
  }
}
