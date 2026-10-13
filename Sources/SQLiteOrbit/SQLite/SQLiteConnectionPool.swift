/// Pools native connections without owning transactions or observer subscriptions.
///
/// Callers choose transaction boundaries and install observers inside each synchronous loan.
/// Writer loans are barriers by default; explicit concurrent loans may overlap reads and other
/// concurrent writers. Choose a journal mode that supports the intended concurrency through
/// `writerConfiguration`'s ``SQLiteConfiguration/journalMode``, which the writers apply before
/// any reader opens. Readers are opened read-only and never apply a journal mode.
///
/// ```swift
/// var writerConfiguration = SQLiteConfiguration.default
/// writerConfiguration.journalMode = .wal
/// let pool = try SQLiteConnectionPool(
///   path: .file(url),
///   readerConfiguration: .default,
///   writerConfiguration: writerConfiguration
/// )
/// let count = try await pool.withReadConnection { connection in
///   try connection.transaction { transaction in
///     try transaction.fetchOne("SELECT count(*) FROM reminders") { $0[0].integerValue }
///   }
/// }
/// ```
///
/// Borrowed connections cannot escape their closure. Every loan ends after connection cleanup,
/// including when the closure throws.
public final class SQLiteConnectionPool: OrbitSuspendable {
  /// The database this pool's connections are open on.
  public let path: OrbitDatabasePath

  private let scheduler: SQLitePoolScheduler
  private let writerSuspensions: [SQLiteWriteSuspension]
  private let suspended = Lock(false)

  /// Opens writable connections first, then the read-only connections for the same database.
  ///
  /// Both connection counts must be positive. Readers are opened read-only, and the pool runs
  /// `PRAGMA query_only = 1` on each of them itself, so raw SQL that attempts a write through a
  /// reader fails with an explicit error.
  ///
  /// Role-specific setup runs after each configuration's setup, with the driver's privilege rather
  /// than the configuration's authorization, and is not included in the configuration reported by
  /// borrowed connections. This primitive does not coordinate opening with other processes; a
  /// multiprocess driver must arrange that coordination.
  ///
  /// - Parameters:
  ///   - path: The database file. A database private to its connection cannot be pooled.
  ///   - readerConfiguration: The settings applied to every reader.
  ///   - writerConfiguration: The settings applied to every writer, including the journal mode
  ///     the database runs in.
  ///   - readerCount: The number of read-only connections to open.
  ///   - writerCount: The number of writable connections to open.
  ///   - readerSetups: The driver's own setups for each reader.
  ///   - writerSetups: The driver's own setups for each writer.
  /// - Precondition: `readerCount` and `writerCount` must be greater than zero.
  /// - Throws: ``SQLitePoolUnavailableError`` for a database private to its connection, or a
  ///   ``SQLiteError`` when a connection cannot be opened or configured.
  public init(
    path: OrbitDatabasePath,
    readerConfiguration: SQLiteConfiguration,
    writerConfiguration: SQLiteConfiguration,
    readerCount: Int = 5,
    writerCount: Int = 1,
    readerSetups: [SQLiteSetup] = [],
    writerSetups: [SQLiteSetup] = []
  ) throws {
    precondition(
      readerCount > 0,
      "A connection pool requires at least one reader"
    )
    precondition(writerCount > 0, "A connection pool requires at least one writer")
    guard !path.isPrivateToConnection else { throw SQLitePoolUnavailableError(path: path) }
    let suspensions = (0..<writerCount).map { _ in SQLiteWriteSuspension(path: path) }
    let writers = try suspensions.map { suspension in
      try SQLiteSerialConnection(
        path: path,
        configuration: writerConfiguration,
        flags: [.readWrite, .create, .noMutex],
        setups: writerSetups,
        suspension: suspension
      )
    }
    // The read-only flag is the real protection. `query_only` also gives raw SQL attempted
    // through a reader an explicit error.
    let readers = try (0..<readerCount)
      .map { _ in
        try SQLiteSerialConnection(
          path: path,
          configuration: readerConfiguration,
          flags: [.readOnly, .noMutex],
          setups: [.sql("PRAGMA query_only = 1")] + readerSetups,
          suspension: nil
        )
      }
    self.path = path
    self.scheduler = SQLitePoolScheduler(readers: readers, writers: writers)
    self.writerSuspensions = suspensions
  }

  /// Lends a reader, waiting behind earlier barrier writes.
  public func withReadConnection<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await scheduler.readWithoutTransaction(body)
  }

  /// Lends a writer after earlier loans finish, holding later loans until it returns.
  public func withWriteConnection<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await scheduler.writeWithoutTransaction(body)
  }

  /// Lends a writer that may overlap readers and other concurrent writer loans.
  /// Choose a transaction mode that supports concurrent writers.
  public func withConcurrentWriteConnection<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await scheduler.writeWithoutTransaction(concurrent: true, body)
  }

  /// Lends a reader, blocking the calling thread. Never call from a cooperative task.
  public func withReadConnectionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try scheduler.readWithoutTransactionBlocking(body)
  }

  /// Lends a writer as a barrier, blocking the calling thread. Never call from a cooperative task.
  public func withWriteConnectionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try scheduler.writeWithoutTransactionBlocking(body)
  }

  /// Lends a concurrent writer, blocking the calling thread. Never call from a cooperative task.
  /// Choose a transaction mode that supports concurrent writers.
  public func withConcurrentWriteConnectionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try scheduler.writeWithoutTransactionBlocking(concurrent: true, body)
  }

  /// Captures the finite set of writer loans active now. Later loans do not extend the wait.
  ///
  /// A writer stays active through its whole loan, including any commit notification delivered
  /// by `body`. A snapshot taken from such a notification includes that writer itself.
  public func captureActiveWriters() -> (any OrbitDatabaseWriterBarrier)? {
    scheduler.captureActiveWriters()
  }

  /// Whether writer statements that could retain a write lock are currently refused.
  public var isSuspended: Bool { suspended.withLock { $0 } }

  /// Interrupts the current writers and refuses statements that could retain a write lock.
  /// Read-only connections remain available. This does not wait for rollback to finish.
  public func suspend() {
    suspended.withLock { suspended in
      guard !suspended else { return }
      for suspension in writerSuspensions { suspension.suspend() }
      suspended = true
    }
  }

  /// Allows writer statements again.
  public func resume() {
    suspended.withLock { suspended in
      guard suspended else { return }
      for suspension in writerSuspensions { suspension.resume() }
      suspended = false
    }
  }
}
