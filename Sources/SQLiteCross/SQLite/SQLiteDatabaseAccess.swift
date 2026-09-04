/// A native SQLite database that lends read transactions.
///
/// The concrete transaction type deliberately makes this a seam between the package's native
/// queue and pool implementations, not a general-purpose driver abstraction.
public protocol SQLiteDatabaseReader: Sendable {
  func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result

  /// Runs `body` in a read transaction, blocking the calling thread until it finishes.
  func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result
}

/// A native SQLite database that lends read and write transactions.
public protocol SQLiteDatabaseWriter: SQLiteDatabaseReader {
  /// The identifier used when an ``InterprocessDatabase`` does not receive an explicit one.
  var defaultIdentifier: DatabaseIdentifier { get }

  func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result

  /// Runs `body` in a write transaction, blocking the calling thread until it finishes.
  func writeBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result
}
