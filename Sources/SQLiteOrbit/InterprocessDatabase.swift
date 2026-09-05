/// The public database handle that coordinates local transactions with other processes.
///
/// A database announces every write it commits so that processes sharing the same SQLite file can
/// react to each other's work. When its writer is observable, it also combines the writer's local
/// transaction events with committed writes announced by its peers.
///
/// Use ``OrbitDatabase`` unless you are supplying your own writer or transport.
///
/// ```swift
/// @Table struct Reminder { let id: Int; var title: String; var isCompleted = false }
///
/// let database = try OrbitDatabase(path: DatabasePath("reminders.sqlite"))
/// try await database.write { transaction in
///   try Reminder.insert { Reminder.Draft(title: "Buy milk") }.execute(transaction)
/// }
/// ```
public final class InterprocessDatabase<Writer: SQLiteDatabaseWriter>:
  Identifiable,
  SQLiteDatabaseWriter,
  Sendable
{
  /// The identity shared by every process that opens this database.
  public let id: DatabaseIdentifier

  /// The driver that lends this database its read and write transactions.
  public let writer: Writer

  /// The identifier this database uses when one is not supplied, which is ``id``.
  public var defaultIdentifier: DatabaseIdentifier { id }

  private let transport: (any DatabaseIPCTransport)?
  private let onAnnouncementFailure: (@Sendable (any Error) -> Void)?

  /// Creates a database that announces its committed writes through `transport`.
  ///
  /// - Parameters:
  ///   - writer: The driver that lends read and write transactions.
  ///   - id: The identity shared by every process that opens this database. Defaults to the
  ///     writer's own identifier.
  ///   - transport: The transport used to announce committed writes. A `nil` transport confines the
  ///     database to the current process.
  ///   - onAnnouncementFailure: Receives the error when announcing a committed write fails. The
  ///     write has already committed by then, so the failure is never surfaced to its caller.
  ///
  /// ```swift
  /// let database = InterprocessDatabase(
  ///   writer: try SQLiteQueueDriver(path: .memory),
  ///   id: DatabaseIdentifier(rawValue: "reminders"),
  ///   transport: InMemoryIPCTransport(network: network)
  /// )
  /// ```
  public init(
    writer: Writer,
    id: DatabaseIdentifier? = nil,
    transport: (any DatabaseIPCTransport)? = nil,
    onAnnouncementFailure: (@Sendable (any Error) -> Void)? = nil
  ) {
    self.writer = writer
    self.id = id ?? writer.defaultIdentifier
    self.transport = transport
    self.onAnnouncementFailure = onAnnouncementFailure
  }

  /// Reads from the database inside a transaction.
  ///
  /// ```swift
  /// let reminders = try await database.read { try $0.fetchAll(Reminder.all) }
  /// ```
  ///
  /// - Parameter body: Reads the value from a read transaction.
  /// - Returns: Whatever `body` returns.
  /// - Throws: Whatever `body` or the underlying driver throws.
  public func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await writer.read(body)
  }

  /// Reads from the database inside a transaction, blocking the calling thread.
  ///
  /// ```swift
  /// let count = try database.readBlocking { try $0.fetchCount(Reminder.all) }
  /// ```
  ///
  /// - Parameter body: Reads the value from a read transaction.
  /// - Returns: Whatever `body` returns.
  /// - Throws: Whatever `body` or the underlying driver throws.
  public func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try writer.readBlocking(body)
  }

  /// Writes to the database and announces the transaction it commits.
  ///
  /// A write that throws is rolled back by its writer and is not announced. The announcement is
  /// complete by the time this method returns, so a peer that observes the database has already
  /// been told about the commit.
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   try Reminder.insert { Reminder.Draft(title: "Buy milk") }.execute(transaction)
  /// }
  /// ```
  ///
  /// - Parameter body: Performs the write inside a write transaction.
  /// - Returns: Whatever `body` returns.
  /// - Throws: Whatever `body` or the underlying driver throws. An announcement failure is
  ///   reported to `onAnnouncementFailure` instead.
  public func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    let result = try await writer.write(body)
    reportLocalCommit()
    await Task { await self.announceCommittedTransaction() }.value
    return result
  }

  /// Writes to the database synchronously and announces the transaction it commits.
  ///
  /// The durable write completes before this method returns. Since IPC transports are
  /// asynchronous, its announcement continues in an independent task, so a peer may not have been
  /// told about the commit yet.
  ///
  /// ```swift
  /// try database.writeBlocking { transaction in
  ///   try Reminder.update { $0.isCompleted = true }.execute(transaction)
  /// }
  /// ```
  ///
  /// - Parameter body: Performs the write inside a write transaction.
  /// - Returns: Whatever `body` returns.
  /// - Throws: Whatever `body` or the underlying driver throws.
  public func writeBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    let result = try writer.writeBlocking(body)
    reportLocalCommit()
    Task { await self.announceCommittedTransaction() }
    return result
  }

  private func reportLocalCommit() {
    guard let observableWriter = writer as? any SQLiteObservableDatabase else { return }
    InterprocessDatabaseObservationHub.shared.didCommit(
      databaseIdentifier: id,
      writerIdentifier: ObjectIdentifier(observableWriter)
    )
  }

  /// Announces a committed write once the writer has released its write transaction.
  ///
  /// Announcing outside the transaction matters: a peer told about a commit must be able to read
  /// it, and holding SQLite's write lock while waiting on a backpressured peer would turn one
  /// stalled process into a stalled database. Callers run this in an unstructured `Task`, which
  /// starts uncancelled, so cancelling the write cannot cut short an announcement of a commit that
  /// already happened. The transaction is durable by then, so a failed announcement never fails it.
  private func announceCommittedTransaction() async {
    guard let transport else { return }
    let message = DatabaseIPCMessage.transactionDidCommit(
      DatabaseTransactionDidCommit(databaseIdentifier: id)
    )
    do {
      try await transport.send(message)
    } catch {
      onAnnouncementFailure?(error)
    }
  }
}

extension InterprocessDatabase: SQLiteObservableDatabase where Writer: SQLiteObservableDatabase {
  /// Observes local transactions from the underlying writer and commits announced by peer
  /// processes.
  ///
  /// The observer sees three sources of commits as one stream: this handle's own writes, writes by
  /// another handle on the same database in this process (both reported as
  /// ``DatabaseTransactionOrigin/local``), and writes announced by another process (reported as
  /// ``DatabaseTransactionOrigin/external``).
  ///
  /// ```swift
  /// let subscription = try database.subscribe(transactionObserver: CommitLogger())
  /// ```
  ///
  /// - Parameter transactionObserver: The observer to register.
  /// - Returns: A subscription that unregisters the observer from every source when cancelled.
  /// - Throws: An error if the writer or the transport refuses the registration.
  public func subscribe(
    transactionObserver: any DatabaseTransactionObserver
  ) throws -> OrbitSubscription {
    let local = try writer.subscribe(transactionObserver: transactionObserver)
    let sameProcess = InterprocessDatabaseObservationHub.shared.subscribe(
      to: id,
      writerIdentifier: ObjectIdentifier(writer)
    ) {
      transactionObserver.databaseDidCommit(DatabaseCommit(origin: .local))
    }
    guard let transport else {
      return OrbitSubscription {
        local.cancel()
        sameProcess.cancel()
      }
    }

    do {
      let external = try transport.subscribe(to: id) { message in
        guard case .transactionDidCommit = message else { return }
        transactionObserver.databaseDidCommit(DatabaseCommit(origin: .external))
      }
      return OrbitSubscription {
        local.cancel()
        sameProcess.cancel()
        external.cancel()
      }
    } catch {
      local.cancel()
      sameProcess.cancel()
      throw error
    }
  }
}

/// Delivers commits between distinct handles in this process. The IPC transport excludes its own
/// endpoint, and two wrappers around the same writer already share that writer's observer registry,
/// so registrations are keyed by both database and writer identity.
private final class InterprocessDatabaseObservationHub: Sendable {
  static let shared = InterprocessDatabaseObservationHub()

  private struct Registration: Sendable {
    let writerIdentifier: ObjectIdentifier
    let onCommit: @Sendable () -> Void
  }

  private let registrations = Lock(KeyedHandlerRegistry<DatabaseIdentifier, Registration>())

  func subscribe(
    to databaseIdentifier: DatabaseIdentifier,
    writerIdentifier: ObjectIdentifier,
    onCommit: @escaping @Sendable () -> Void
  ) -> OrbitSubscription {
    let identifier = registrations.withLock {
      $0.insert(
        Registration(writerIdentifier: writerIdentifier, onCommit: onCommit),
        for: databaseIdentifier
      )
      .identifier
    }
    return OrbitSubscription { [weak self] in
      _ = self?.registrations.withLock { $0.remove(identifier, for: databaseIdentifier) }
    }
  }

  func didCommit(
    databaseIdentifier: DatabaseIdentifier,
    writerIdentifier: ObjectIdentifier
  ) {
    let callbacks = registrations.withLock { registrations in
      registrations.handlers(for: databaseIdentifier)
        .filter { $0.writerIdentifier != writerIdentifier }
        .map(\.onCommit)
    }
    for callback in callbacks { callback() }
  }
}
