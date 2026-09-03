/// A native SQLite database that lends read transactions.
///
/// The concrete transaction type deliberately makes this a seam between the package's native
/// queue and pool implementations, not a general-purpose driver abstraction.
public protocol SQLiteDatabaseReader: Sendable {
  nonisolated(nonsending)
  func read<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) async throws -> sending Result
}

/// A native SQLite database that lends read and write transactions.
public protocol SQLiteDatabaseWriter: SQLiteDatabaseReader {
  /// The identifier used when a ``CrossProcessDatabase`` does not receive an explicit one.
  var defaultIdentifier: DatabaseIdentifier { get }

  nonisolated(nonsending)
  func write<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteWriteTransaction) throws -> sending Result
  ) async throws -> sending Result
}
