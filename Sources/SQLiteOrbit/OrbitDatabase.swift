/// The public database handle that coordinates local transactions with other processes.
///
/// A database announces every write it commits so that processes sharing the same SQLite file can
/// react to each other's work. When its writer is observable, it also combines the writer's local
/// transaction events with committed writes announced by its peers.
///
/// Opening one by path alone gives an `OrbitDatabase<SQLitePool>` reaching its peers over the
/// package's own transport, which is what all but a caller supplying their own writer or transport
/// wants.
///
/// ```swift
/// @Table struct Reminder { let id: Int; var title: String; var isCompleted = false }
///
/// let database = try OrbitDatabase(path: OrbitDatabasePath("reminders.sqlite"))
/// try await database.write { transaction in
///   try Reminder.insert { Reminder.Draft(title: "Buy milk") }.execute(transaction)
/// }
/// ```
public final class OrbitDatabase<Writer: OrbitDatabaseWriter>:
  Identifiable,
  OrbitDatabaseWriter,
  Sendable
{
  /// The identity shared by every process that opens this database.
  public let id: OrbitDatabaseIdentifier

  /// The driver that lends this database its read and write transactions.
  public let writer: Writer

  /// The identifier this database uses when one is not supplied, which is ``id``.
  public var defaultIdentifier: OrbitDatabaseIdentifier { id }

  private let transport: (any OrbitIPCTransport)?
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
  /// let database = OrbitDatabase(
  ///   writer: try SQLiteQueue(path: .memory),
  ///   id: OrbitDatabaseIdentifier(rawValue: "reminders"),
  ///   transport: InMemoryIPCTransport(network: network)
  /// )
  /// ```
  public init(
    writer: Writer,
    id: OrbitDatabaseIdentifier? = nil,
    transport: (any OrbitIPCTransport)? = nil,
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
  /// been told about the commit and the union of its changed regions.
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
    let (result, region) = try await writer.write { transaction in
      try transaction.recordingDatabaseRegion(body)
    }
    reportLocalCommit(in: region)
    await Task { await self.announceCommittedTransaction(in: region) }.value
    return result
  }

  /// Writes to the database synchronously and announces the transaction it commits.
  ///
  /// The durable write completes before this method returns. Since IPC transports are
  /// asynchronous, its announcement continues in an independent task, so a peer may not have been
  /// told about the commit and the union of its changed regions yet.
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
    let (result, region) = try writer.writeBlocking { transaction in
      try transaction.recordingDatabaseRegion(body)
    }
    reportLocalCommit(in: region)
    Task { await self.announceCommittedTransaction(in: region) }
    return result
  }

  /// Reads from the database outside a transaction.
  ///
  /// ```swift
  /// let integrity = try await database.readWithoutTransaction { connection in
  ///   try connection.fetchAll(#sql("PRAGMA integrity_check", as: String.self))
  /// }
  /// ```
  ///
  /// - Parameter body: Reads the value from a connection whose statements each run in their own
  ///   implicit transaction. A busy timeout it changes through the connection is restored when
  ///   the access ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returns.
  /// - Throws: Whatever `body` or the underlying driver throws.
  public func readWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await writer.readWithoutTransaction(body)
  }

  /// Reads from the database outside a transaction, blocking the calling thread.
  ///
  /// ```swift
  /// let integrity = try database.readWithoutTransactionBlocking { connection in
  ///   try connection.fetchAll(#sql("PRAGMA integrity_check", as: String.self))
  /// }
  /// ```
  ///
  /// - Parameter body: Reads the value from a connection whose statements each run in their own
  ///   implicit transaction. A busy timeout it changes through the connection is restored when
  ///   the access ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returns.
  /// - Throws: Whatever `body` or the underlying driver throws.
  public func readWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try writer.readWithoutTransactionBlocking(body)
  }

  /// Writes to the database outside a transaction and announces what it commits.
  ///
  /// Each statement commits on its own, and each ``SQLiteWriteConnection/transaction(_:)`` commits
  /// as a whole, so the access as a whole is announced once, after `body` is done, as the union of
  /// the regions that committed. A transaction that rolled back is left out. A `body` that throws
  /// is announced too, since whatever committed before the failure stays committed, and an access
  /// that committed nothing is not announced at all. The announcement is complete by the time this
  /// method returns or throws.
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
  /// - Parameter body: Performs the writes on a connection whose statements each commit on their
  ///   own. The busy timeout and foreign keys it changes through the connection are restored
  ///   when the access ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returns.
  /// - Throws: Whatever `body` or the underlying driver throws. An announcement failure is
  ///   reported to `onAnnouncementFailure` instead.
  public func writeWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    let recorder = OrbitDatabaseRegionRecorder()
    do {
      let result = try await writer.writeWithoutTransaction { connection in
        try connection.recordingDatabaseRegion(into: recorder, body)
      }
      await announceCommits(recordedBy: recorder)
      return result
    } catch {
      await announceCommits(recordedBy: recorder)
      throw error
    }
  }

  /// Writes to the database outside a transaction synchronously and announces what it commits.
  ///
  /// The access is announced as ``writeWithoutTransaction(_:)`` announces it, but since IPC
  /// transports are asynchronous, the announcement continues in an independent task, so a peer
  /// may not have been told about it yet when this method returns or throws.
  ///
  /// ```swift
  /// try database.writeWithoutTransactionBlocking { connection in
  ///   try connection.execute("VACUUM")
  /// }
  /// ```
  ///
  /// - Parameter body: Performs the writes on a connection whose statements each commit on their
  ///   own. The busy timeout and foreign keys it changes through the connection are restored
  ///   when the access ends; any other pragma it changes must be restored before it returns.
  /// - Returns: Whatever `body` returns.
  /// - Throws: Whatever `body` or the underlying driver throws.
  public func writeWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    let recorder = OrbitDatabaseRegionRecorder()
    defer {
      if recorder.hasCommitted {
        let region = recorder.committedRegion
        reportLocalCommit(in: region)
        Task { await self.announceCommittedTransaction(in: region) }
      }
    }
    return try writer.writeWithoutTransactionBlocking { connection in
      try connection.recordingDatabaseRegion(into: recorder, body)
    }
  }

  private func announceCommits(recordedBy recorder: OrbitDatabaseRegionRecorder) async {
    guard recorder.hasCommitted else { return }
    let region = recorder.committedRegion
    reportLocalCommit(in: region)
    await Task { await self.announceCommittedTransaction(in: region) }.value
  }

  private func reportLocalCommit(in region: OrbitDatabaseRegion) {
    guard let observableWriter = writer as? any OrbitObservableDatabase else { return }
    OrbitDatabaseObservationHub.shared.didCommit(
      databaseIdentifier: id,
      writerIdentifier: ObjectIdentifier(observableWriter),
      region: region
    )
  }

  private func announceCommittedTransaction(in region: OrbitDatabaseRegion) async {
    guard let transport else { return }
    let message = OrbitIPCMessage.transactionDidCommit(
      OrbitDatabaseTransactionDidCommit(databaseIdentifier: id, region: region)
    )
    do {
      try await transport.send(message)
    } catch {
      onAnnouncementFailure?(error)
    }
  }
}

extension OrbitDatabase: OrbitObservableDatabase where Writer: OrbitObservableDatabase {
  /// Observes local transactions from the underlying writer and commits announced by peer
  /// processes.
  ///
  /// The observer sees three sources of commits as one stream: this handle's own writes, writes by
  /// another handle on the same database in this process (both reported as
  /// ``OrbitDatabaseTransactionOrigin/local``), and writes announced by another process (reported
  /// as ``OrbitDatabaseTransactionOrigin/external``).
  ///
  /// ```swift
  /// let subscription = try database.subscribe(transactionObserver: CommitLogger())
  /// ```
  ///
  /// - Parameter transactionObserver: The observer to register.
  /// - Returns: A subscription that unregisters the observer from every source when cancelled.
  /// - Throws: An error if the writer or the transport refuses the registration.
  public func subscribe(
    transactionObserver: any OrbitDatabaseTransactionObserver
  ) throws -> OrbitSubscription {
    let local = try writer.subscribe(transactionObserver: transactionObserver)
    let sameProcess = OrbitDatabaseObservationHub.shared.subscribe(
      to: id,
      writerIdentifier: ObjectIdentifier(writer)
    ) { region in
      transactionObserver.databaseDidChange(in: region)
      transactionObserver.databaseDidCommit(OrbitDatabaseCommit(origin: .local))
    }
    guard let transport else {
      return OrbitSubscription {
        local.cancel()
        sameProcess.cancel()
      }
    }

    do {
      let external = try transport.subscribe(to: id) { message in
        guard case .transactionDidCommit(let commit) = message else { return }
        transactionObserver.databaseDidChange(in: commit.region)
        transactionObserver.databaseDidCommit(OrbitDatabaseCommit(origin: .external))
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

private final class OrbitDatabaseObservationHub: Sendable {
  static let shared = OrbitDatabaseObservationHub()

  private struct Registration: Sendable {
    let writerIdentifier: ObjectIdentifier
    let onCommit: @Sendable (OrbitDatabaseRegion) -> Void
  }

  private let registrations = Lock(KeyedHandlerRegistry<OrbitDatabaseIdentifier, Registration>())

  func subscribe(
    to databaseIdentifier: OrbitDatabaseIdentifier,
    writerIdentifier: ObjectIdentifier,
    onCommit: @escaping @Sendable (OrbitDatabaseRegion) -> Void
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
    databaseIdentifier: OrbitDatabaseIdentifier,
    writerIdentifier: ObjectIdentifier,
    region: OrbitDatabaseRegion
  ) {
    let callbacks = registrations.withLock { registrations in
      registrations.handlers(for: databaseIdentifier)
        .filter { $0.writerIdentifier != writerIdentifier }
        .map(\.onCommit)
    }
    for callback in callbacks { callback(region) }
  }
}

/// Records the regions an access changes, keeping apart those whose transaction has committed from
/// those whose transaction has not ended yet.
///
/// A change is pending until the transaction it was made in commits, when it joins the committed
/// region, or rolls back, when it is discarded. An access that runs several transactions can then
/// announce only what actually committed.
final class OrbitDatabaseRegionRecorder: OrbitDatabaseTransactionObserver, Sendable {
  private struct Regions {
    var committed = OrbitDatabaseRegion.empty
    var pending = OrbitDatabaseRegion.empty
    var hasCommitted = false
  }

  private let regions = Lock(Regions())

  /// Whether a transaction committed while this recorder was registered, even one that changed
  /// nothing.
  var hasCommitted: Bool { regions.withLock { $0.hasCommitted } }

  /// The union of the changes whose transaction has committed while this recorder was registered.
  var committedRegion: OrbitDatabaseRegion { regions.withLock { $0.committed } }

  /// Every change not rolled back while this recorder was registered, committed or not.
  ///
  /// A write transaction commits after its body returns and so after the recorder scoped to the
  /// body is gone, which leaves all of its changes pending here.
  var changedRegion: OrbitDatabaseRegion {
    regions.withLock { $0.committed.union($0.pending) }
  }

  func databaseDidChange(in region: OrbitDatabaseRegion) {
    regions.withLock { $0.pending.formUnion(region) }
  }

  func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    regions.withLock { regions in
      regions.committed.formUnion(regions.pending)
      regions.pending = .empty
      regions.hasCommitted = true
    }
  }

  func databaseDidRollback() {
    regions.withLock { $0.pending = .empty }
  }
}

extension SQLiteWriteTransaction {
  fileprivate borrowing func recordingDatabaseRegion<Result: Sendable>(
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) rethrows -> (Result, OrbitDatabaseRegion) {
    let recorder = OrbitDatabaseRegionRecorder()
    let result = try base.observations.withObserver(recorder) {
      try body(self)
    }
    return (result, recorder.changedRegion)
  }
}

extension SQLiteWriteConnection {
  fileprivate borrowing func recordingDatabaseRegion<Result: Sendable>(
    into recorder: OrbitDatabaseRegionRecorder,
    _ body: (borrowing SQLiteWriteConnection) throws -> Result
  ) rethrows -> Result {
    let observations = base.base.observations
    return try observations.withObserver(recorder) {
      // A change still pending once the body is done was made outside a transaction, and so has
      // committed. The handle would only report that after the access, when the recorder is gone.
      defer { observations.didCommitPendingChanges() }
      return try body(self)
    }
  }
}
