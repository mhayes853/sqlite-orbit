/// Reported when a database cannot be pooled.
///
/// Thrown by a connection pool for a database that is private to the connection that opens it.
///
/// ```swift
/// do {
///   _ = try SQLitePool(path: .memory)
/// } catch let error as SQLitePoolUnavailableError {
///   print(error.path)
/// }
/// ```
public struct SQLitePoolUnavailableError: Error, CustomStringConvertible {
  /// The path that cannot be pooled.
  public let path: OrbitDatabasePath

  /// Explains why the path cannot be pooled and which driver to use instead.
  public var description: String {
    """
    A database private to the connection that opened it cannot be pooled: a pool's readers would \
    each see a different, empty database. Use SQLiteQueue for "\(path)".
    """
  }
}

/// An ``OrbitDatabaseWriter`` that runs reads concurrently against a pool of connections while
/// serializing writes through one.
///
/// Reads run alongside one another. A write waits for the reads in flight and holds off the reads
/// queued behind it, so a read issued after a write observes it. The database runs in WAL mode so
/// that other processes' readers are never blocked by this one's writer.
///
/// ```swift
/// let driver = try SQLitePool(path: .file(url))
/// try await driver.write { transaction in
///   try transaction.execute(Reminder.insert { Reminder(id: 1, title: "Get milk") })
/// }
/// let reminders = try await driver.read { try $0.fetchAll(Reminder.all) }
/// ```
///
/// A pool does not coordinate with other processes. Switching a new database to WAL briefly needs
/// an exclusive lock, so several processes opening the same database with bare pools at the same
/// moment may fail with `SQLITE_BUSY`, and none of them hears about the others' writes. To share a
/// database between processes, open it with ``OrbitIPCDatabase``, which serializes opening across
/// processes and announces each commit to the others.
public final class SQLitePool: OrbitMultiprocessDatabaseWriter, OrbitObservableDatabase {
  /// The database this pool's connections are open on.
  public let path: OrbitDatabasePath

  private let pool: SQLiteConnectionPool
  private let transactionObservers = OrbitCompositeDatabaseTransactionObserver()

  /// Opens `path` as a WAL database with one writer and `readerCount` readers.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.busyPolicy = .timeout(.seconds(10))
  /// let driver = try SQLitePool(path: .file(url), configuration: configuration, readerCount: 8)
  /// ```
  ///
  /// The writer switches the database to WAL whatever `configuration`'s
  /// ``SQLiteConfiguration/journalMode`` says, before any of `configuration`'s setups run.
  ///
  /// - Parameters:
  ///   - path: The database file. A database private to its connection cannot be pooled.
  ///   - configuration: The settings applied to every connection.
  ///   - readerCount: The number of reader connections to open. Must be greater than zero.
  /// - Precondition: `readerCount` must be greater than zero.
  /// - Throws: ``SQLitePoolUnavailableError`` for a database private to its connection, or a
  ///   ``SQLiteError`` when a connection cannot be opened or configured, including one with
  ///   `SQLITE_BUSY` when another process holds a lock on the database for longer than
  ///   `configuration`'s busy policy waits.
  public init(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration,
    readerCount: Int = 5
  ) throws {
    precondition(readerCount > 0, "SQLitePool requires at least one reader")
    guard !path.isPrivateToConnection else {
      throw SQLitePoolUnavailableError(path: path)
    }
    var writerConfiguration = configuration
    writerConfiguration.journalMode = .wal
    self.pool = try SQLiteConnectionPool(
      path: path,
      readerConfiguration: configuration,
      writerConfiguration: writerConfiguration,
      readerCount: readerCount,
      // Switching to WAL does not create the `-wal` and `-shm` files; the next transaction does. A
      // read-only connection cannot create them itself, and Apple's SQLite then fails to open a
      // new database at all, so the writer reads once to leave them in place for the readers.
      writerSetups: [.sql("SELECT count(*) FROM sqlite_schema")]
    )
    self.path = path
  }

  /// Runs `body` in a read transaction on one of the pool's readers.
  ///
  /// The read waits for any write that is running or already queued, so it observes every write
  /// issued before it.
  ///
  /// - Parameter body: Receives the transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled while waiting or running.
  public func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await pool.withReadConnection { connection in
      try connection.transaction(observer: transactionObservers, body)
    }
  }

  /// Runs `body` in a read transaction, blocking the calling thread until it finishes.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the very machinery the rest of the pool runs on.
  ///
  /// - Parameter body: Receives the transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``.
  public func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try pool.withReadConnectionBlocking { connection in
      try connection.transaction(observer: transactionObservers, body)
    }
  }

  /// Runs `body` in a write transaction on the pool's single writer.
  ///
  /// The write waits for the reads already in flight, and holds off the reads queued behind it
  /// until it commits.
  ///
  /// - Parameter body: Receives the transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled while waiting or running.
  public func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    try await pool.withWriteConnection { connection in
      try connection.transaction(observer: transactionObservers, body)
    }
  }

  /// Runs `body` in a write transaction, blocking the calling thread until it finishes.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the very machinery the rest of the pool runs on.
  ///
  /// - Parameter body: Receives the transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``.
  public func writeBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try pool.withWriteConnectionBlocking { connection in
      try connection.transaction(observer: transactionObservers, body)
    }
  }

  /// Runs `body` with one of the pool's readers, reading outside a transaction.
  ///
  /// The access waits for any write that is running or already queued, like ``read(_:)``.
  ///
  /// ```swift
  /// let mode = try await driver.readWithoutTransaction { connection in
  ///   try connection.fetchOne(#sql("PRAGMA journal_mode", as: String.self))
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement runs in its own implicit
  ///   transaction. A busy policy it changes through the connection is restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled while waiting or running.
  public func readWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await pool.withReadConnection { connection in
      try connection.withObservation(transactionObservers) { try body(connection) }
    }
  }

  /// Runs `body` with one of the pool's readers, reading outside a transaction and blocking the
  /// calling thread until it finishes.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the very machinery the rest of the pool runs on.
  ///
  /// ```swift
  /// let mode = try driver.readWithoutTransactionBlocking { connection in
  ///   try connection.fetchOne(#sql("PRAGMA journal_mode", as: String.self))
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement runs in its own implicit
  ///   transaction. A busy policy it changes through the connection is restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``.
  public func readWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try pool.withReadConnectionBlocking { connection in
      try connection.withObservation(transactionObservers) { try body(connection) }
    }
  }

  /// Runs `body` with the pool's single writer, writing outside a transaction.
  ///
  /// The access is admitted like ``write(_:)`` and holds the writer for its whole duration, so
  /// this process's pool reads queued behind it wait until `body` returns, even between its
  /// statements.
  ///
  /// ```swift
  /// try await driver.writeWithoutTransaction { connection in
  ///   try connection.execute("VACUUM")
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement commits on its own. The busy
  ///   policy and foreign keys it changes through the connection are restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled while waiting or running. Statements that finished before the failure stay
  ///   committed.
  public func writeWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await pool.withWriteConnection { connection in
      try connection.withObservation(transactionObservers) { try body(connection) }
    }
  }

  /// Runs `body` with the pool's single writer, writing outside a transaction and blocking the
  /// calling thread until it finishes.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the very machinery the rest of the pool runs on.
  ///
  /// ```swift
  /// try driver.writeWithoutTransactionBlocking { connection in
  ///   try connection.execute("VACUUM")
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement commits on its own. The busy
  ///   policy and foreign keys it changes through the connection are restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``. Statements that finished before the
  ///   failure stay committed.
  public func writeWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try pool.withWriteConnectionBlocking { connection in
      try connection.withObservation(transactionObservers) { try body(connection) }
    }
  }

  /// Whether this pool currently refuses statements that could retain its writer's lock.
  public var isSuspended: Bool { pool.isSuspended }

  /// Interrupts an active writer and refuses statements that could acquire or retain its lock.
  /// Reads on the pool's read-only connections continue to work. An interrupted write rolls back
  /// and throws ``OrbitDatabaseSuspendedError``. A transactional write rolls back; earlier
  /// statements in `writeWithoutTransaction` may already have committed. This method does not
  /// wait for an active transaction to roll back.
  public func suspend() { pool.suspend() }

  /// Allows writes to acquire the lock again. Calling this when active has no effect.
  public func resume() { pool.resume() }

  /// Registers an observer of the transactions this driver commits.
  ///
  /// Every transaction this driver reports happens in this process, so it reports all of them
  /// whatever `region` says, and updating the region has no effect.
  ///
  /// - Parameters:
  ///   - transactionObserver: Receives reads and each changed region, commit, and rollback.
  ///   - region: The region the observer cares about.
  /// - Returns: A subscription that stops the observer when it is cancelled or released.
  public func subscribe(
    transactionObserver: any OrbitDatabaseTransactionObserver,
    region: OrbitDatabaseRegion
  ) throws -> OrbitRegionSubscription {
    transactionObservers.subscribe(transactionObserver, region: region)
  }
}

#if BuiltInSQLite
  extension SQLitePool {
    /// Opens a pooled database using the SQLite this package was linked against.
    ///
    /// ```swift
    /// let driver = try SQLitePool(path: .file(url))
    /// ```
    ///
    /// - Parameters:
    ///   - path: The database file. A database private to its connection cannot be pooled.
    ///   - readerCount: The number of reader connections to open. Must be greater than zero.
    /// - Precondition: `readerCount` must be greater than zero.
    /// - Throws: ``SQLitePoolUnavailableError`` for a database private to its connection, or a
    ///   ``SQLiteError`` when a connection cannot be opened.
    public convenience init(path: OrbitDatabasePath, readerCount: Int = 5) throws {
      try self.init(path: path, configuration: .default, readerCount: readerCount)
    }
  }
#endif
