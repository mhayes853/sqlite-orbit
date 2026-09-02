import Dispatch
import Synchronization

/// One open connection, run on a dispatch queue of its own.
///
/// Every access hops to the connection's queue, as GRDB gives each connection a queue, so a query
/// never occupies a cooperative-pool thread and callers waiting their turn queue as jobs rather
/// than blocking. The lock exists to satisfy the type system's ownership of the noncopyable handle;
/// with all access on one queue it is never contended.
final class SQLiteConnection: Sendable {
  private let handle: Mutex<SQLiteHandle>
  private let executor = SQLiteConnectionExecutor()

  /// Aborts whatever query is running, without taking the lock.
  ///
  /// Taking the lock would deadlock against the very query this is meant to stop, so the pointer
  /// and entry point are captured up front. The pointer crosses threads as an address so that this
  /// stays `Sendable` without an unchecked conformance; it remains valid because the closure and
  /// the handle are released together.
  private let interrupt: @Sendable () -> Void

  init(path: String, flags: SQLiteOpenFlags, configuration: SQLiteConfiguration) throws {
    // A handle opened here is the only owner of itself, which is what lets it be handed to the
    // lock. One received as a parameter would already belong to the caller's task.
    let handle = try SQLiteHandle.open(path: path, flags: flags, configuration: configuration)
    let address = UInt(bitPattern: handle.pointer)
    let entryPoint = handle.library.pointee.interrupt
    self.interrupt = { entryPoint(OpaquePointer(bitPattern: address)) }
    self.handle = Mutex(handle)
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

  /// Runs `work` on the connection's queue, interrupting it if the task is cancelled meanwhile.
  ///
  /// SQLite reports an interrupted statement as `SQLITE_INTERRUPT`, which is a cancellation rather
  /// than a database failure and is reported as one.
  private func perform<Result: Sendable>(
    _ work: @Sendable (borrowing SQLiteHandle) throws -> sending Result
  ) async throws -> sending Result {
    try Task.checkCancellation()
    do {
      return try await withTaskCancellationHandler {
        try await withTaskExecutorPreference(executor) {
          try await run(work)
        }
      } onCancel: {
        interrupt()
      }
    } catch let error as SQLiteError where error.primaryCode == .interrupt {
      throw CancellationError()
    }
  }

  @concurrent
  private func run<Result: Sendable>(
    _ work: @Sendable (borrowing SQLiteHandle) throws -> sending Result
  ) async throws -> sending Result {
    // Interrupting only affects a statement that is already running, so a task cancelled while it
    // waited its turn on the queue would otherwise go on to run its query in full. What remains is
    // the few microseconds between this check and the first step; closing that would take a
    // progress handler, which is not worth its cost per opcode.
    try Task.checkCancellation()
    return try handle.withLock { handle in try work(handle) }
  }
}

/// A serial dispatch queue, as a task executor.
///
/// Being a task executor is what lets a `nonisolated(nonsending)` driver method hop here from
/// whatever isolation called it: a `@concurrent` function honors the task's executor preference.
final class SQLiteConnectionExecutor: TaskExecutor {
  private let queue = DispatchQueue(label: "SQLiteCross.connection")

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async {
      job.runSynchronously(on: self.asUnownedTaskExecutor())
    }
  }
}
