import Synchronization

/// Shared ownership of one connection, so that asynchronous and synchronous access can serialize
/// against each other.
///
/// Asynchronous access serializes on ``SQLiteConnectionActor``, which suspends rather than blocks.
/// The lock exists only so a synchronous caller, which cannot enter an actor, still cannot run at
/// the same time as one. In the common case it is uncontended.
final class SQLiteConnectionStorage: Sendable {
  let connection: Mutex<SQLiteConnection>

  /// Aborts whatever query is running, without taking the lock.
  ///
  /// Taking the lock here would deadlock against the very query this is meant to stop, so the
  /// handle and entry point are captured up front. SQLite documents interrupting from another
  /// thread as supported.
  let interrupt: @Sendable () -> Void

  /// Opens the connection here rather than accepting one.
  ///
  /// A connection opened locally is the only owner of itself, which is what lets it be handed to
  /// the lock. One received as a parameter would already belong to the caller's task.
  init(
    path: String,
    flags: SQLiteOpenFlags,
    configuration: SQLiteConfiguration
  ) throws {
    let connection = try SQLiteConnection.open(
      path: path,
      flags: flags,
      configuration: configuration
    )
    // The handle crosses to another thread as an address rather than a pointer, which is what
    // lets this stay `Sendable` without an unchecked conformance. It stays valid because the
    // closure and the connection are released together.
    let address = UInt(bitPattern: connection.handle)
    let entryPoint = connection.library.pointee.interrupt
    self.interrupt = { entryPoint(OpaquePointer(bitPattern: address)) }
    self.connection = Mutex(connection)
  }
}

/// Serializes asynchronous access to one connection.
///
/// An actor rather than a lock: callers waiting their turn suspend instead of occupying a thread,
/// which is what lets many tasks queue against a single writer without starving the cooperative
/// pool.
actor SQLiteConnectionActor {
  /// Readable without entering the actor, which is what lets a cancellation interrupt the very
  /// query the actor is busy running.
  let storage: SQLiteConnectionStorage

  init(storage: SQLiteConnectionStorage) {
    self.storage = storage
  }

  func read<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) throws -> sending Result {
    try storage.connection.withLock { connection in
      // Interrupting only affects a statement that is already running, so a task cancelled while
      // it waited its turn here would otherwise go on to run its query in full.
      try Task.checkCancellation()
      return try runRead(on: connection, body)
    }
  }

  func write<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteWriteTransaction) throws -> sending Result
  ) throws -> sending Result {
    try storage.connection.withLock { connection in
      try Task.checkCancellation()
      return try runWrite(on: connection, body)
    }
  }
}

/// Runs `operation`, interrupting the connection if the task is cancelled while it is running.
///
/// SQLite reports an interrupted statement as `SQLITE_INTERRUPT`, which is a cancellation rather
/// than a database failure and is reported as one.
///
/// Interrupting is a no-op when no statement is running, so this alone would drop a cancellation
/// that arrived before the first step. The connection re-checks cancellation once it is free, which
/// covers the long wait; what remains is the few microseconds between that check and the first
/// step. Closing that last gap entirely would take a progress handler, which is not worth its cost
/// per opcode here.
func withInterruptOnCancellation<Result: Sendable>(
  _ storage: SQLiteConnectionStorage,
  _ operation: nonisolated(nonsending) () async throws -> sending Result
) async throws -> sending Result {
  try Task.checkCancellation()
  do {
    return try await withTaskCancellationHandler {
      try await operation()
    } onCancel: {
      storage.interrupt()
    }
  } catch let error as SQLiteError where error.primaryCode == .interrupt {
    throw CancellationError()
  }
}
