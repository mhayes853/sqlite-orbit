import Foundation

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
public final class SQLitePool: OrbitObservableDatabase {
  /// The identity this driver's database is known by across processes.
  public let defaultIdentifier: OrbitDatabaseIdentifier

  private let scheduler: SQLitePoolScheduler
  private let transactionObservers = OrbitDatabaseTransactionObservers()

  /// Opens `path` as a WAL database with one writer and `configuration.readerCount` readers.
  ///
  /// - Parameters:
  ///   - path: The database file. A database private to its connection cannot be pooled.
  ///   - configuration: The settings applied to every connection.
  ///   - identifier: The identity shared with other processes. Defaults to the standardized path.
  ///   - coordinationDirectory: Where the advisory lock that serializes opening lives. Processes
  ///     coordinate only when they share it.
  /// - Throws: ``SQLitePoolUnavailableError`` for a database private to its connection, or a
  ///   ``SQLiteError`` when a connection cannot be opened or configured.
  public init(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration,
    identifier: OrbitDatabaseIdentifier? = nil,
    coordinationDirectory: URL? = nil
  ) throws {
    guard !path.isPrivateToConnection else {
      throw SQLitePoolUnavailableError(path: path)
    }
    let identifier = identifier ?? .forDatabase(path: path)

    // Moving a new database into WAL briefly needs an exclusive lock of SQLite's own, so processes
    // opening it at the same moment would otherwise contend for it.
    let (writer, readers) = try Self.withOpenLock(
      identifier: identifier,
      directory: coordinationDirectory
    ) {
      try Self.openConnections(path: path, configuration: configuration)
    }

    self.defaultIdentifier = identifier
    self.scheduler = SQLitePoolScheduler(readers: readers, writers: [writer])
  }

  private static func openConnections(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration
  ) throws -> (writer: SQLiteSerialConnection, readers: [SQLiteSerialConnection]) {
    // Each connection's role is set up apart from the caller's configuration, which is what its
    // transactions report having been opened with.
    let writer = try SQLiteSerialConnection(
      path: path,
      flags: [.readWrite, .create, .noMutex],
      configuration: configuration,
      driverSetupSQL: ["PRAGMA journal_mode = WAL"]
    )

    // `query_only` is belt and braces over the read-only flag: it turns a write attempted through
    // the raw connection into an error rather than a surprise.
    let readers = try (0..<max(1, configuration.readerCount))
      .map { _ in
        try SQLiteSerialConnection(
          path: path,
          flags: [.readOnly, .noMutex],
          configuration: configuration,
          driverSetupSQL: ["PRAGMA query_only = 1"]
        )
      }
    return (writer, readers)
  }

  private static func withOpenLock<Result>(
    identifier: OrbitDatabaseIdentifier,
    directory: URL?,
    _ body: () throws -> Result
  ) throws -> Result {
    #if canImport(Darwin) || canImport(Glibc)
      return try OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: identifier,
        directory: directory ?? UnixDatagramIPCTransport.Configuration.defaultDirectory,
        body
      )
    #else
      return try body()
    #endif
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
    try await scheduler.read(observers: transactionObservers, body)
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
    try scheduler.readBlocking(observers: transactionObservers, body)
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
    try await scheduler.write(observers: transactionObservers, body)
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
    try scheduler.writeBlocking(observers: transactionObservers, body)
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
  ///   transaction. A busy timeout it changes through the connection is restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled while waiting or running.
  public func readWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await scheduler.readWithoutTransaction(observers: transactionObservers, body)
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
  ///   transaction. A busy timeout it changes through the connection is restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``.
  public func readWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try scheduler.readWithoutTransactionBlocking(observers: transactionObservers, body)
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
  ///   timeout and foreign keys it changes through the connection are restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled while waiting or running. Statements that finished before the failure stay
  ///   committed.
  public func writeWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await scheduler.writeWithoutTransaction(observers: transactionObservers, body)
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
  ///   timeout and foreign keys it changes through the connection are restored when the access
  ///   ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``. Statements that finished before the
  ///   failure stay committed.
  public func writeWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try scheduler.writeWithoutTransactionBlocking(observers: transactionObservers, body)
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
  extension SQLitePool {
    /// Opens a pooled database using the SQLite this package was linked against.
    ///
    /// ```swift
    /// let driver = try SQLitePool(path: .file(url))
    /// ```
    ///
    /// - Parameters:
    ///   - path: The database file. A database private to its connection cannot be pooled.
    ///   - identifier: The identity shared with other processes. Defaults to the standardized path.
    ///   - coordinationDirectory: Where the advisory lock that serializes opening lives.
    /// - Throws: ``SQLitePoolUnavailableError`` for a database private to its connection, or a
    ///   ``SQLiteError`` when a connection cannot be opened.
    public convenience init(
      path: OrbitDatabasePath,
      identifier: OrbitDatabaseIdentifier? = nil,
      coordinationDirectory: URL? = nil
    ) throws {
      try self.init(
        path: path,
        configuration: .default,
        identifier: identifier,
        coordinationDirectory: coordinationDirectory
      )
    }
  }
#endif
