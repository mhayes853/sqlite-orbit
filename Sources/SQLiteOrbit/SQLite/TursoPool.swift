#if Turso
  /// An ``OrbitDatabaseWriter`` that runs reads and writes concurrently using Turso's MVCC mode.
  ///
  /// Reads use a fixed set of read-only connections, while writes use a separate fixed set of
  /// writable connections and `BEGIN CONCURRENT`. Reads and writes may overlap, and writes that
  /// modify distinct rows may commit concurrently. Turso reports a conflict between overlapping
  /// writes as a ``SQLiteError``; the driver rolls the failed transaction back but does not replay
  /// its body.
  ///
  /// ```swift
  /// let driver = try TursoPool(path: .file(url))
  /// try await driver.write { transaction in
  ///   try transaction.execute(Reminder.insert { Reminder(id: 1, title: "Get milk") })
  /// }
  /// ```
  public final class TursoPool: OrbitObservableDatabase {
    /// The identity this driver's database is known by within the process.
    public let defaultIdentifier: OrbitDatabaseIdentifier

    private let scheduler: SQLitePoolScheduler
    private let transactionObservers = OrbitDatabaseTransactionObservers()

    /// Opens `path` in Turso's MVCC mode.
    ///
    /// - Parameters:
    ///   - path: The database file. A database private to its connection cannot be pooled.
    ///   - configuration: Settings applied to every connection. Its library should be Turso.
    ///   - writerCount: The number of concurrent write connections to open. Values below one are
    ///     treated as one.
    ///   - identifier: The identity used by an ``OrbitDatabase`` when one is not supplied.
    /// - Throws: ``SQLitePoolUnavailableError`` for a database private to its connection, or a
    ///   ``SQLiteError`` when a connection cannot be opened or configured for MVCC.
    public init(
      path: OrbitDatabasePath,
      configuration: SQLiteConfiguration = .turso,
      writerCount: Int = 4,
      identifier: OrbitDatabaseIdentifier? = nil
    ) throws {
      guard !path.isPrivateToConnection else {
        throw SQLitePoolUnavailableError(path: path)
      }

      // Establish MVCC on writable connections before opening readers. The setup is prepended so
      // caller-supplied setup SQL always runs against the mode this driver promises.
      var writerConfiguration = configuration
      writerConfiguration.setupSQL.insert("PRAGMA journal_mode = MVCC", at: 0)
      let writers = try (0..<max(1, writerCount))
        .map { _ in
          try SQLiteConnection(
            path: path,
            flags: [.readWrite, .create, .noMutex],
            configuration: writerConfiguration
          )
        }

      // The read-only flag is the real protection. `query_only` also gives raw SQL attempted
      // through a read transaction an explicit error.
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

      self.defaultIdentifier = identifier ?? .forDatabase(path: path)
      self.scheduler = SQLitePoolScheduler(readers: readers, writers: writers)
    }

    /// Runs `body` in a read transaction on one of the pool's reader connections.
    ///
    /// The read may overlap writes already in flight and sees a consistent Turso snapshot. A read
    /// begun after an awaited write completes observes that write.
    public func read<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) async throws -> Result {
      try await scheduler.read(observers: transactionObservers, body)
    }

    /// Runs `body` in a concurrent Turso write transaction.
    ///
    /// A commit conflict is rolled back and thrown as a ``SQLiteError``. The body is never retried
    /// implicitly.
    public func write<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) async throws -> Result {
      let ((result, region), barrier) = try await scheduler.writeTrackingConcurrentWriters {
        transaction in
        try transaction.recordingDatabaseRegion(body)
      }
      transactionObservers.didChange(in: region)
      transactionObservers.didCommit(
        origin: .local,
        region: region,
        activeWriterBarrier: barrier
      )
      return result
    }

    /// Runs `body` in an immediate transaction after every ordinary pool access has finished.
    ///
    /// Use this for schema work or another operation that must not overlap concurrent transactions.
    /// Requests issued after this one wait behind it until it completes.
    public func exclusiveWrite<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) async throws -> Result {
      try await scheduler.write(observers: transactionObservers, body)
    }

    /// Runs `body` in a read transaction, blocking the calling thread until it finishes.
    ///
    /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
    ///   starves the machinery the rest of the database runs on.
    public func readBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) throws -> Result {
      try scheduler.readBlocking(observers: transactionObservers, body)
    }

    /// Runs `body` in a concurrent write transaction, blocking the calling thread.
    ///
    /// Calls made from different threads may run concurrently. A conflict is thrown without
    /// replaying `body`.
    public func writeBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result {
      let ((result, region), barrier) = try scheduler.writeBlockingTrackingConcurrentWriters {
        transaction in
        try transaction.recordingDatabaseRegion(body)
      }
      transactionObservers.didChange(in: region)
      transactionObservers.didCommit(
        origin: .local,
        region: region,
        activeWriterBarrier: barrier
      )
      return result
    }

    /// Runs an immediate transaction exclusively, blocking the calling thread until it finishes.
    public func exclusiveWriteBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result {
      try scheduler.writeBlocking(observers: transactionObservers, body)
    }

    /// Registers an observer of reads and successfully committed writes.
    ///
    /// Concurrent writes publish their aggregate changed region only after committing, followed
    /// immediately by the commit. A conflicting or otherwise failed write publishes nothing.
    public func subscribe(
      transactionObserver: any OrbitDatabaseTransactionObserver
    ) throws -> OrbitSubscription {
      transactionObservers.subscribe(transactionObserver)
    }
  }
#endif
