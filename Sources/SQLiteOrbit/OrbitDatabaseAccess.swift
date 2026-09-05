/// A native SQLite database that lends read transactions.
///
/// The concrete transaction type deliberately makes this a seam between the package's native
/// queue and pool implementations, not a general-purpose driver abstraction.
///
/// ```swift
/// func countReminders(in database: some OrbitDatabaseReader) async throws -> Int {
///   try await database.read { transaction in
///     try transaction.fetchCount(Reminder.all)
///   }
/// }
/// ```
public protocol OrbitDatabaseReader: Sendable {
  /// Runs `body` in a read transaction.
  ///
  /// The transaction sees one consistent snapshot for its whole duration.
  ///
  /// - Parameter body: Receives the transaction. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when the transaction cannot be opened.
  func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result

  /// Runs `body` in a read transaction, blocking the calling thread until it finishes.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the machinery the rest of the database runs on.
  ///
  /// - Parameter body: Receives the transaction. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when the transaction cannot be opened.
  func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result
}

/// A native SQLite database that lends read and write transactions.
///
/// ```swift
/// func complete(_ id: Int, in database: some OrbitDatabaseWriter) async throws {
///   try await database.write { transaction in
///     try transaction.execute(Reminder.where { $0.id.eq(id) }.update { $0.isCompleted = true })
///   }
/// }
/// ```
public protocol OrbitDatabaseWriter: OrbitDatabaseReader {
  /// The identifier used when an ``OrbitDatabase`` does not receive an explicit one.
  var defaultIdentifier: OrbitDatabaseIdentifier { get }

  /// Runs `body` in a write transaction, committing it when `body` returns.
  ///
  /// A `body` that throws rolls the transaction back, so nothing it wrote is kept.
  ///
  /// - Parameter body: Receives the transaction. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when the transaction cannot be opened
  ///   or committed.
  func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result

  /// Runs `body` in a write transaction, blocking the calling thread until it finishes.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the machinery the rest of the database runs on.
  ///
  /// - Parameter body: Receives the transaction. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when the transaction cannot be opened
  ///   or committed.
  func writeBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result
}
