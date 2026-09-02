/// A ``DatabaseDriver`` that serializes every access through a single connection.
///
/// This is the driver for a database that does not benefit from concurrent readers: an in-memory
/// database, which is private to the connection that opened it and so cannot be pooled at all, or a
/// small file database where one connection is plenty. ``SQLitePoolDriver`` is the choice when
/// reads should run concurrently.
public final class SQLiteQueueDriver: DatabaseDriver, Sendable {
  public typealias ReadTransaction = SQLiteReadTransaction
  public typealias WriteTransaction = SQLiteWriteTransaction

  public let defaultIdentifier: DatabaseIdentifier

  private let storage: SQLiteConnectionStorage
  private let queue: SQLiteConnectionActor

  /// Opens a database at `path`, or an in-memory database when `path` is `":memory:"`.
  public init(
    path: String,
    configuration: SQLiteConfiguration,
    identifier: DatabaseIdentifier? = nil
  ) throws {
    let storage = try SQLiteConnectionStorage(
      path: path,
      flags: [.readWrite, .create, .noMutex],
      configuration: configuration
    )
    self.storage = storage
    self.queue = SQLiteConnectionActor(storage: storage)
    self.defaultIdentifier = identifier ?? .forDatabase(path: path)
  }

  nonisolated(nonsending)
  public func read<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await withInterruptOnCancellation(storage) {
      try await queue.read(body)
    }
  }

  nonisolated(nonsending)
  public func write<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteWriteTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await withInterruptOnCancellation(storage) {
      try await queue.write(body)
    }
  }

  /// Reads without an asynchronous context, blocking the calling thread until the connection is
  /// free.
  ///
  /// Prefer ``read(_:)``, which suspends instead of blocking. This exists for the callers that have
  /// no `await` available to them, such as work during application launch.
  ///
  /// There is deliberately no synchronous counterpart for writing. A database has exactly one
  /// writer, so a synchronous write is the easiest way to tie up a thread waiting for it, and the
  /// asynchronous form can wait without occupying one.
  /// The body is `@Sendable` because the connection it is lent is shared with the tasks reading
  /// through ``read(_:)``, and so cannot be joined to the calling task's isolation.
  public func readSynchronously<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) throws -> sending Result {
    try storage.connection.withLock { connection in
      try runRead(on: connection, body)
    }
  }
}

#if SystemSQLite
  extension SQLiteQueueDriver {
    /// Opens a database using the SQLite this package was linked against.
    public convenience init(
      path: String,
      identifier: DatabaseIdentifier? = nil
    ) throws {
      try self.init(path: path, configuration: .default, identifier: identifier)
    }
  }
#endif
