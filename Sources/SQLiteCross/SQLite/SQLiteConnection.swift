import Dispatch
import Foundation

/// One open connection, isolated to a dispatch queue of its own.
///
/// The connection is an actor whose executor is that queue. Two things follow from it. A query
/// never occupies a thread of the cooperative
/// pool, which is a pool of a few threads that Swift expects nothing to block; a query blocks its
/// own queue instead. And callers waiting their turn suspend as ordinary actor hops, so
/// cancellation and task locals propagate the way they would for any other actor, rather than
/// having to be carried across a continuation by hand.
///
/// The handle is ordinary isolated state, so the connection needs no lock of its own.
actor SQLiteConnection {
  private var handle: SQLiteHandle
  private let executor: SQLiteConnectionExecutor
  private let interrupt: @Sendable () -> Void

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }

  init(path: String, flags: SQLiteOpenFlags, configuration: SQLiteConfiguration) throws {
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

  nonisolated(nonsending)
  func read<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await perform { handle in try handle.read(body) }
  }

  nonisolated(nonsending)
  func write<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteWriteTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await perform { handle in try handle.write(body) }
  }

  /// Hops to the connection's queue and runs `work` there, cancellably.
  ///
  /// The cancellation handler is installed before the hop, so a task cancelled while it is still
  /// waiting its turn is noticed. SQLite reports an interrupted statement as `SQLITE_INTERRUPT`,
  /// which is a cancellation rather than a database failure and is reported as one.
  nonisolated(nonsending)
  private func perform<Result: Sendable>(
    _ work: @Sendable (borrowing SQLiteHandle) throws -> sending Result
  ) async throws -> sending Result {
    // The token belongs to this access alone. A cancellation that arrives while this access is
    // still queued finds it unarmed and does nothing, rather than interrupting whichever *other*
    // access currently owns the connection.
    let token = SQLiteInterruptToken()
    do {
      return try await withTaskCancellationHandler {
        try await run(work, token: token)
      } onCancel: {
        token.fire()
      }
    } catch let error as SQLiteError where error.primaryCode == .interrupt {
      throw CancellationError()
    }
  }

  /// Runs `work` on the connection's queue, holding the interrupt for the duration.
  private func run<Result: Sendable>(
    _ work: @Sendable (borrowing SQLiteHandle) throws -> sending Result,
    token: SQLiteInterruptToken
  ) throws -> sending Result {
    token.arm(interrupt)
    defer { token.disarm() }
    // Interrupting only affects a statement that is already running, so a task cancelled while it
    // waited its turn on the queue would otherwise go on to run its query in full. What remains is
    // the few microseconds between this check and the first step; closing that would take a
    // progress handler, which is not worth its cost per opcode.
    try Task.checkCancellation()
    return try work(handle)
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
/// Cancellation can arrive at any moment, including while an access is still queued behind another
/// one. Interrupting then would abort whatever *other* access is running on the connection, which
/// was never cancelled — so each access gets a token of its own, and it only fires between the
/// moment that access takes the connection and the moment it gives it back.
///
/// Interrupting deliberately does not wait for the connection: taking its queue here would
/// deadlock against the very query this is meant to stop. SQLite documents interrupting from
/// another thread as supported.
private final class SQLiteInterruptToken: @unchecked Sendable {
  /// Guarded by `lock`, which is held only for the moments around arming, so it is never contended
  /// for long.
  private var interrupt: (@Sendable () -> Void)?
  private let lock = NSLock()

  func arm(_ interrupt: @escaping @Sendable () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    self.interrupt = interrupt
  }

  func disarm() {
    lock.lock()
    defer { lock.unlock() }
    interrupt = nil
  }

  func fire() {
    lock.lock()
    let interrupt = self.interrupt
    lock.unlock()
    // Called outside the lock: the access it stops will take the lock on its way out.
    interrupt?()
  }
}
