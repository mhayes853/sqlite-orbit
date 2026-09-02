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

  private let connection: SQLiteConnection

  /// Opens a database at `path`, or an in-memory database when `path` is `":memory:"`.
  public init(
    path: String,
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

  nonisolated(nonsending)
  public func read<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await connection.read(body)
  }

  nonisolated(nonsending)
  public func write<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteWriteTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await connection.write(body)
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
