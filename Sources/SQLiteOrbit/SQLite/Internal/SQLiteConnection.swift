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

  init(path: OrbitDatabasePath, flags: SQLiteOpenFlags, configuration: SQLiteConfiguration) throws {
    let handle = try SQLiteHandle.open(path: path, flags: flags, configuration: configuration)
    // The connection is captured as an address rather than a pointer, which is what lets this
    // closure be shared without an unchecked conformance on `OpaquePointer`. It stays valid
    // because the closure and the handle are released together.
    let address = UInt(bitPattern: handle.pointer)
    let entryPoint = handle.library.pointee.interrupt
    self.interrupt = { entryPoint(OpaquePointer(bitPattern: address)) }
    self.executor = SQLiteConnectionExecutor(path: path)
    self.handle = handle
  }

  func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.read(body) }
  }

  func write<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.write(observers: observers, body) }
  }

  /// Runs `body` on the connection's queue, blocking the calling thread until it finishes.
  ///
  /// This is `nonisolated` because a blocking caller has no way to enter the actor. It reaches
  /// isolated state through the executor's queue instead, which is the same mutual exclusion the
  /// actor itself runs on, so the isolation is real rather than assumed.
  nonisolated func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try performBlocking { handle in try handle.read(body) }
  }

  nonisolated func writeBlocking<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try performBlocking { handle in try handle.write(observers: observers, body) }
  }

  /// A blocking access carries no task, so there is no cancellation to arm the interrupt for.
  private nonisolated func performBlocking<Result: Sendable>(
    _ work: sending (borrowing SQLiteHandle) throws -> Result
  ) throws -> Result {
    nonisolated(unsafe) let work = work
    return try executor.sync {
      try self.assumeIsolated { connection in
        try work(connection.handle)
      }
    }
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

  /// Marks each connection queue with the executor that owns it, so a blocking access can tell
  /// whether it is already on the queue it is about to wait for.
  private static let owner = DispatchSpecificKey<ObjectIdentifier>()

  init(path: OrbitDatabasePath) {
    // The queue is labelled with the database it serves, because a stack of blocked threads is
    // most of what a hang report of this package will show.
    self.queue = DispatchQueue(
      label: "SQLiteOrbit.connection(\(path))",
      autoreleaseFrequency: .workItem
    )
    queue.setSpecific(key: Self.owner, value: ObjectIdentifier(self))
  }

  /// Runs `body` on the queue, blocking the caller until it finishes.
  func sync<Result>(_ body: () throws -> Result) rethrows -> Result {
    precondition(
      DispatchQueue.getSpecific(key: Self.owner) != ObjectIdentifier(self),
      """
      A blocking database access cannot be nested inside another one on the same connection: \
      the inner access would wait for the outer one to release a connection it still holds. \
      Use the transaction already in hand rather than opening a second one.
      """
    )
    return try queue.sync(execute: body)
  }

  func enqueue(_ job: consuming ExecutorJob) {
    // The job's priority is handed to dispatch rather than dropped. Without it every query would
    // run at the queue's own QoS, so a read a user is waiting on would be served no sooner than a
    // background one, and the thread running it would not be raised to match. Dispatch also
    // resolves the inversion this leaves behind: a high-priority block enqueued behind a
    // low-priority one raises the queue until it drains.
    let qos = Self.dispatchQoS(for: job.priority)
    let job = UnownedJob(job)
    queue.async(qos: qos) {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }

  func checkIsolated() {
    dispatchPrecondition(condition: .onQueue(queue))
  }

  /// The dispatch QoS closest to a job's priority.
  ///
  /// `TaskPriority` and `DispatchQoS` name the same four bands, but the priorities in between are
  /// a caller's business, so each one rounds down to the band it belongs to. A job with no
  /// priority of its own is left to inherit the queue's.
  private static func dispatchQoS(for priority: JobPriority) -> DispatchQoS {
    guard let priority = TaskPriority(priority) else { return .unspecified }
    if priority >= .high { return .userInitiated }
    if priority >= .medium { return .default }
    if priority >= .low { return .utility }
    return .background
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
