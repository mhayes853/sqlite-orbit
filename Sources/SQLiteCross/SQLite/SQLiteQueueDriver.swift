/// A ``SQLiteDatabaseWriter`` that serializes every access through a single connection.
///
/// This is the driver for a database that does not benefit from concurrent readers: an in-memory
/// database, which is private to the connection that opened it and so cannot be pooled at all, or a
/// small file database where one connection is plenty. ``SQLitePoolDriver`` is the choice when
/// reads should run concurrently.
public final class SQLiteQueueDriver: SQLiteObservableDatabase {
  public let defaultIdentifier: DatabaseIdentifier

  private let connection: SQLiteConnection
  private let transactionObservers = DatabaseTransactionObservers()

  /// Opens the database at `path`, creating it when it does not exist.
  public init(
    path: DatabasePath,
    configuration: SQLiteConfiguration,
    identifier: DatabaseIdentifier? = nil
  ) throws {
    self.connection = try SQLiteConnection(
      path: path,
      flags: [.readWrite, .create, .noMutex],
      configuration: configuration
    )
    self.defaultIdentifier = identifier ?? .forDatabase(path: path)
  }

  public func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await connection.read(body)
  }

  public func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    try await connection.write(observers: transactionObservers, body)
  }

  /// Runs `body` in a read transaction, blocking the calling thread until it finishes.
  public func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try connection.readBlocking(body)
  }

  /// Runs `body` in a write transaction, blocking the calling thread until it finishes.
  public func writeBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try connection.writeBlocking(observers: transactionObservers, body)
  }

  public func subscribe(
    transactionObserver: any DatabaseTransactionObserver
  ) throws -> SQLiteCrossSubscription {
    transactionObservers.subscribe(transactionObserver)
  }
}

#if SystemSQLite
  extension SQLiteQueueDriver {
    /// Opens a database using the SQLite this package was linked against.
    public convenience init(
      path: DatabasePath,
      identifier: DatabaseIdentifier? = nil
    ) throws {
      try self.init(path: path, configuration: .default, identifier: identifier)
    }
  }
#endif
