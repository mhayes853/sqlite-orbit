/// Pools native connections without owning transactions or observer subscriptions.
///
/// Callers choose transaction boundaries and install observers inside each synchronous loan.
/// Writer loans are barriers by default; explicit concurrent loans may overlap reads and other
/// concurrent writers. Configure a journal mode that supports the intended concurrency before
/// readers open, using `writerConfiguration` or `writerSetupSQL`.
public final class SQLiteConnectionPool: OrbitSuspendable {
  private let scheduler: SQLitePoolScheduler
  private let writerSuspensions: [SQLiteWriteSuspension]
  private let suspended = Lock(false)

  /// Opens writable connections first, then the read-only connections for the same database.
  ///
  /// The reader count comes from `readerConfiguration.readerCount`. Both counts must be positive.
  /// Role-specific setup runs after each configuration's setup and is not included in the
  /// configuration reported by borrowed connections. This primitive does not coordinate opening
  /// with other processes; a multiprocess driver must arrange that coordination.
  public init(
    path: OrbitDatabasePath,
    readerConfiguration: SQLiteConfiguration,
    writerConfiguration: SQLiteConfiguration,
    writerCount: Int = 1,
    readerSetupSQL: [String] = [],
    writerSetupSQL: [String] = [],
    identifier: OrbitDatabaseIdentifier? = nil
  ) throws {
    precondition(
      readerConfiguration.readerCount > 0,
      "A connection pool requires at least one reader"
    )
    precondition(writerCount > 0, "A connection pool requires at least one writer")
    guard !path.isPrivateToConnection else { throw SQLitePoolUnavailableError(path: path) }
    let databaseIdentifier = identifier ?? .forDatabase(path: path)
    let suspensions = (0..<writerCount)
      .map { _ in
        SQLiteWriteSuspension(databaseIdentifier: databaseIdentifier)
      }
    let writers = try suspensions.map { suspension in
      try SQLiteSerialConnection(
        path: path,
        flags: [.readWrite, .create, .noMutex],
        configuration: writerConfiguration,
        driverSetupSQL: writerSetupSQL,
        suspension: suspension
      )
    }
    let readers = try (0..<readerConfiguration.readerCount)
      .map { _ in
        try SQLiteSerialConnection(
          path: path,
          flags: [.readOnly, .noMutex],
          configuration: readerConfiguration,
          driverSetupSQL: readerSetupSQL
        )
      }
    self.scheduler = SQLitePoolScheduler(readers: readers, writers: writers)
    self.writerSuspensions = suspensions
  }

  /// Lends a reader, waiting behind earlier barrier writes.
  ///
  /// The connection cannot escape `body`. An error releases the loan after the connection
  /// cleans up its access. Concurrent writer loans require an appropriate transaction mode.
  public func withReadConnection<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await scheduler.readWithoutTransaction(body)
  }

  /// Lends a writer after earlier loans finish, holding later loans until it returns.
  ///
  /// The connection cannot escape `body`. An error releases the loan after the connection
  /// cleans up its access. Concurrent writer loans require an appropriate transaction mode.
  public func withWriteConnection<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await scheduler.writeWithoutTransaction(body)
  }

  /// Lends a writer that may overlap readers and other concurrent writer loans.
  ///
  /// The connection cannot escape `body`. An error releases the loan after the connection
  /// cleans up its access. Concurrent writer loans require an appropriate transaction mode.
  public func withConcurrentWriteConnection<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await scheduler.concurrentWriteWithoutTransaction(body)
  }

  /// Lends a reader, blocking the calling thread. Never call from a cooperative task.
  ///
  /// The connection cannot escape `body`. An error releases the loan after the connection
  /// cleans up its access. Concurrent writer loans require an appropriate transaction mode.
  public func withReadConnectionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try scheduler.readWithoutTransactionBlocking(body)
  }

  /// Lends a writer as a barrier, blocking the calling thread. Never call from a cooperative task.
  ///
  /// The connection cannot escape `body`. An error releases the loan after the connection
  /// cleans up its access. Concurrent writer loans require an appropriate transaction mode.
  public func withWriteConnectionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try scheduler.writeWithoutTransactionBlocking(body)
  }

  /// Lends a concurrent writer, blocking the calling thread. Never call from a cooperative task.
  ///
  /// The connection cannot escape `body`. An error releases the loan after the connection
  /// cleans up its access. Concurrent writer loans require an appropriate transaction mode.
  public func withConcurrentWriteConnectionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try scheduler.concurrentWriteWithoutTransactionBlocking(body)
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
