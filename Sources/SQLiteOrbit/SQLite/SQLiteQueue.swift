/// An ``OrbitDatabaseWriter`` that serializes every access through a single connection.
///
/// This is the driver for a database that does not benefit from concurrent readers: an in-memory
/// database, which is private to the connection that opened it and so cannot be pooled at all, or a
/// small file database where one connection is plenty. ``SQLitePool`` is the choice when
/// reads should run concurrently.
///
/// ```swift
/// let driver = try SQLiteQueue(path: ":memory:")
/// try await driver.write { transaction in
///   try transaction.execute(
///     """
///     CREATE TABLE reminders (
///       id INTEGER PRIMARY KEY, title TEXT NOT NULL, isCompleted INTEGER NOT NULL DEFAULT 0
///     )
///     """
///   )
///   try transaction.execute(Reminder.insert { Reminder(id: 1, title: "Get milk") })
/// }
/// let reminders = try await driver.read { try $0.fetchAll(Reminder.all) }
/// ```
public final class SQLiteQueue: OrbitObservableDatabase {
  /// The identity this driver's database is known by across processes.
  public let defaultIdentifier: OrbitDatabaseIdentifier

  private let connection: SQLiteSerialConnection
  private let transactionObservers = OrbitDatabaseTransactionObservers()

  /// Opens the database at `path`, creating it when it does not exist.
  ///
  /// - Parameters:
  ///   - path: Where the database lives. Every path is usable, including `.memory`.
  ///   - configuration: The settings applied to the connection.
  ///   - identifier: The identity shared with other processes. Defaults to the standardized path,
  ///     or a unique identity for a database private to its connection.
  /// - Throws: A ``SQLiteError`` when the database cannot be opened or configured.
  public init(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration,
    identifier: OrbitDatabaseIdentifier? = nil
  ) throws {
    self.connection = try SQLiteSerialConnection(
      path: path,
      flags: [.readWrite, .create, .noMutex],
      configuration: configuration
    )
    self.defaultIdentifier = identifier ?? .forDatabase(path: path)
  }

  /// Runs `body` in a read transaction on the driver's one connection.
  ///
  /// - Parameter body: Receives the transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled.
  public func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await connection.read(observers: transactionObservers, body)
  }

  /// Runs `body` in a write transaction, committing it when `body` returns and rolling it back
  /// when `body` throws.
  ///
  /// - Parameter body: Receives the transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled.
  public func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    try await connection.write(observers: transactionObservers, body)
  }

  /// Runs `body` in a read transaction, blocking the calling thread until it finishes.
  ///
  /// - Important: Never call this from a task, and never from inside another access on this
  ///   driver — the nested access waits for a connection the outer one still holds.
  ///
  /// - Parameter body: Receives the transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``.
  public func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try connection.readBlocking(observers: transactionObservers, body)
  }

  /// Runs `body` in a write transaction, blocking the calling thread until it finishes.
  ///
  /// - Important: Never call this from a task, and never from inside another access on this
  ///   driver.
  ///
  /// - Parameter body: Receives the transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``.
  public func writeBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try connection.writeBlocking(observers: transactionObservers, body)
  }

  /// Runs `body` with the driver's one connection, reading outside a transaction.
  ///
  /// ```swift
  /// let mode = try await driver.readWithoutTransaction { connection in
  ///   try connection.fetchOne(#sql("PRAGMA journal_mode", as: String.self))
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement runs in its own implicit
  ///   transaction. A busy timeout it changes through the connection is restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled.
  public func readWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await connection.readWithoutTransaction(observers: transactionObservers, body)
  }

  /// Runs `body` with the driver's one connection, writing outside a transaction.
  ///
  /// ```swift
  /// try await driver.writeWithoutTransaction { connection in
  ///   try connection.execute("VACUUM")
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement commits on its own. The busy
  ///   timeout and foreign keys it changes through the connection are restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled. Statements that finished before the failure stay committed.
  public func writeWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await connection.writeWithoutTransaction(observers: transactionObservers, body)
  }

  /// Runs `body` with the driver's one connection, reading outside a transaction and blocking the
  /// calling thread until it finishes.
  ///
  /// - Important: Never call this from a task, and never from inside another access on this
  ///   driver.
  ///
  /// ```swift
  /// let mode = try driver.readWithoutTransactionBlocking { connection in
  ///   try connection.fetchOne(#sql("PRAGMA journal_mode", as: String.self))
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement runs in its own implicit
  ///   transaction. A busy timeout it changes through the connection is restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``.
  public func readWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try connection.readWithoutTransactionBlocking(observers: transactionObservers, body)
  }

  /// Runs `body` with the driver's one connection, writing outside a transaction and blocking the
  /// calling thread until it finishes.
  ///
  /// - Important: Never call this from a task, and never from inside another access on this
  ///   driver.
  ///
  /// ```swift
  /// try driver.writeWithoutTransactionBlocking { connection in
  ///   try connection.execute("VACUUM")
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement commits on its own. The busy
  ///   timeout and foreign keys it changes through the connection are restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``. Statements that finished before the
  ///   failure stay committed.
  public func writeWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try connection.writeWithoutTransactionBlocking(observers: transactionObservers, body)
  }

  /// Registers an observer of the transactions this driver commits.
  ///
  /// - Parameter transactionObserver: Receives reads and each changed region, commit, and rollback.
  /// - Returns: A subscription that stops the observer when it is cancelled or released.
  public func subscribe(
    transactionObserver: any OrbitDatabaseTransactionObserver
  ) throws -> OrbitSubscription {
    transactionObservers.subscribe(transactionObserver)
  }
}

#if BuiltInSQLite
  extension SQLiteQueue {
    /// Opens a database using the SQLite this package was linked against.
    ///
    /// ```swift
    /// let driver = try SQLiteQueue(path: ":memory:")
    /// ```
    ///
    /// - Parameters:
    ///   - path: Where the database lives.
    ///   - identifier: The identity shared with other processes. Defaults to the standardized path.
    /// - Throws: A ``SQLiteError`` when the database cannot be opened or configured.
    public convenience init(
      path: OrbitDatabasePath,
      identifier: OrbitDatabaseIdentifier? = nil
    ) throws {
      try self.init(path: path, configuration: .default, identifier: identifier)
    }
  }
#endif
