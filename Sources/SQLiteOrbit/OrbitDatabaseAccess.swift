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

  /// Runs `body` with a connection that reads outside a transaction.
  ///
  /// Each statement runs in its own implicit transaction, so consecutive statements may see
  /// different states of the database. Call ``SQLiteReadConnection/transaction(_:)`` for a
  /// consistent snapshot. A ``SQLiteReadConnection/busyTimeout`` that `body` changes is restored
  /// when the access ends, even when `body` throws. Any other pragma that `body` changes stays
  /// changed on the connection, so restore it before returning.
  ///
  /// ```swift
  /// let integrity = try await database.readWithoutTransaction { connection in
  ///   try connection.fetchAll(#sql("PRAGMA integrity_check", as: String.self))
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when a statement fails.
  func readWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result

  /// Runs `body` with a connection that reads outside a transaction, blocking the calling thread
  /// until it finishes.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the machinery the rest of the database runs on.
  ///
  /// ```swift
  /// let integrity = try database.readWithoutTransactionBlocking { connection in
  ///   try connection.fetchAll(#sql("PRAGMA integrity_check", as: String.self))
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when a statement fails.
  func readWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
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

  /// Runs `body` with a connection that writes outside a transaction.
  ///
  /// Each statement commits on its own as it finishes, so a `body` that throws leaves every
  /// statement before the failing one committed. Group statements that must commit together with
  /// ``SQLiteWriteConnection/transaction(_:)``. This is for the work a transaction gets in the way
  /// of, such as turning foreign keys off, which has no effect inside one.
  ///
  /// The ``SQLiteWriteConnection/busyTimeout`` and foreign key enforcement that `body` changes
  /// through the connection are restored when the access ends, even when `body` throws. Any other
  /// pragma that `body` changes stays changed on the connection, so restore it before returning.
  ///
  /// ```swift
  /// try await database.writeWithoutTransaction { connection in
  ///   connection.isForeignKeysEnabled = false
  ///   try connection.transaction { transaction in
  ///     try transaction.execute("DROP TABLE reminders")
  ///   }
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when a statement fails.
  func writeWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result

  /// Runs `body` with a connection that writes outside a transaction, blocking the calling thread
  /// until it finishes.
  ///
  /// Each statement commits on its own as it finishes. The busy timeout and foreign key
  /// enforcement that `body` changes through the connection are restored when the access ends;
  /// any other pragma that `body` changes stays changed on the connection, so restore it before
  /// returning.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the machinery the rest of the database runs on.
  ///
  /// ```swift
  /// try database.writeWithoutTransactionBlocking { connection in
  ///   try connection.execute("VACUUM")
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when a statement fails.
  func writeWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result
}
