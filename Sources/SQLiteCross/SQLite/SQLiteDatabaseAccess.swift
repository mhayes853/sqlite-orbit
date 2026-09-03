/// A native SQLite database that lends read transactions.
///
/// The concrete transaction type deliberately makes this a seam between the package's native
/// queue and pool implementations, not a general-purpose driver abstraction.
public protocol SQLiteDatabaseReader: Sendable {
  func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result
}

/// A native SQLite database that lends read and write transactions.
public protocol SQLiteDatabaseWriter: SQLiteDatabaseReader {
  /// The identifier used when a ``CrossProcessDatabase`` does not receive an explicit one.
  var defaultIdentifier: DatabaseIdentifier { get }

  func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result
}
