import Foundation

/// Reported when a database cannot be pooled.
///
/// Thrown by ``SQLitePool/init(path:configuration:identifier:coordinationDirectory:)`` for a
/// database that is private to the connection that opens it.
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

  private let writer: SQLiteConnection
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
    self.writer = writer
    self.scheduler = SQLitePoolScheduler(readers: readers)
  }

  private static func openConnections(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration
  ) throws -> (writer: SQLiteConnection, readers: [SQLiteConnection]) {
    var writerConfiguration = configuration
    writerConfiguration.setupSQL.append("PRAGMA journal_mode = WAL")
    let writer = try SQLiteConnection(
      path: path,
      flags: [.readWrite, .create, .noMutex],
      configuration: writerConfiguration
    )

    // `query_only` is belt and braces over the read-only flag: it turns a write attempted through
    // the raw connection into an error rather than a surprise.
    var readerConfiguration = configuration
    readerConfiguration.setupSQL.append("PRAGMA query_only = 1")
    let readers = try (0..<max(1, configuration.readerCount))
      .map { _ in
        try SQLiteConnection(
          path: path,
          flags: [.readOnly, .noMutex],
          configuration: readerConfiguration
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
    let reader = try await scheduler.acquireReader()
    defer { scheduler.releaseReader(reader) }
    return try await reader.read(observers: transactionObservers, body)
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
    let reader = scheduler.acquireReaderBlocking()
    defer { scheduler.releaseReaderBlocking(reader) }
    return try reader.readBlocking(observers: transactionObservers, body)
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
    try await scheduler.acquireWriter()
    defer { scheduler.releaseWriter() }
    return try await writer.write(observers: transactionObservers, body)
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
    scheduler.acquireWriterBlocking()
    defer { scheduler.releaseWriterBlocking() }
    return try writer.writeBlocking(observers: transactionObservers, body)
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
