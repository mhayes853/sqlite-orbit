import Dispatch

/// One open connection, isolated to a dispatch queue of its own.
///
/// The connection is an actor whose executor is that queue. Two things follow from it. A query
/// never occupies a thread of the cooperative pool, which Swift expects nothing to block; a query
/// blocks its own queue instead. And callers waiting their turn suspend as ordinary actor hops, so
/// cancellation and task locals propagate without being carried across a continuation by hand.
///
/// The handle is ordinary isolated state, so the connection needs no lock of its own.
actor SQLiteConnection {
  private let handle: SQLiteHandle
  private let executor: SQLiteConnectionExecutor
  private let interrupt: @Sendable () -> Void

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }

  init(path: DatabasePath, flags: SQLiteOpenFlags, configuration: SQLiteConfiguration) throws {
    let handle = try SQLiteHandle.open(path: path, flags: flags, configuration: configuration)
    // The connection is captured as an address rather than a pointer, which is what lets this
    // closure be shared without an unchecked conformance on `OpaquePointer`. It stays valid
    // because the closure and the handle are released together.
    let address = UInt(bitPattern: handle.pointer)
    let entryPoint = handle.library.pointee.interrupt
    self.interrupt = { entryPoint(OpaquePointer(bitPattern: address)) }
    self.executor = SQLiteConnectionExecutor(
      queue: DispatchQueue(label: "SQLiteCross.connection")
    )
    self.handle = handle
  }

  func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.read(body) }
  }

  func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.write(body) }
  }

  /// Runs `work` on the connection's queue, holding the interrupt for the duration.
  ///
  /// The token belongs to this access alone, so cancellation cannot interrupt another access that
  /// currently owns the connection. SQLite reports `SQLITE_INTERRUPT` as task cancellation.
  private func perform<Result: Sendable>(
    _ work: sending (borrowing SQLiteHandle) throws -> Result
  ) async throws -> Result {
    let token = SQLiteInterruptToken()
    do {
      return try await withTaskCancellationHandler {
        token.arm(interrupt)
        defer { token.disarm() }
        // A task may have been cancelled while waiting to enter the actor.
        try Task.checkCancellation()
        return try work(handle)
      } onCancel: {
        token.fire()
      }
    } catch let error as SQLiteError where error.primaryCode == .interrupt {
      throw CancellationError()
    }
  }
}

/// A serial dispatch queue, as an actor's executor.
final class SQLiteConnectionExecutor: SerialExecutor {
  private let queue: DispatchQueue

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }

  func checkIsolated() {
    dispatchPrecondition(condition: .onQueue(queue))
  }
}

#if os(Linux) || os(Android) || os(Windows)
  extension SQLiteConnectionExecutor: @unchecked Sendable {}
#endif

/// The interrupt belonging to one access, armed only while that access owns its connection.
///
/// A cancellation handler can race with the end of its operation. Holding the lock while firing
/// prevents a delayed interrupt from reaching the next access after this token is disarmed.
///
/// Interrupting deliberately does not wait for the connection: taking its queue here would
/// deadlock against the very query this is meant to stop. SQLite documents interrupting from
/// another thread as supported.
private final class SQLiteInterruptToken: Sendable {
  /// The lock is held only for the moments around arming, so it is never contended for long.
  private let interrupt = Lock<(@Sendable () -> Void)?>(nil)

  func arm(_ interrupt: @escaping @Sendable () -> Void) {
    self.interrupt.withLock { $0 = interrupt }
  }

  func disarm() {
    interrupt.withLock { $0 = nil }
  }

  func fire() {
    // Invoke while holding the lock so `disarm` cannot let the next access begin first.
    interrupt.withLock { $0?() }
  }
}
