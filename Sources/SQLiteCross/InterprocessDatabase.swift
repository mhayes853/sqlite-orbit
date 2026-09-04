/// The public database handle that coordinates local transactions with other processes.
///
/// A database announces every write it commits so that processes sharing the same SQLite file can
/// react to each other's work. When its writer is observable, it also combines the writer's local
/// transaction events with committed writes announced by its peers.
public final class InterprocessDatabase<Writer: SQLiteDatabaseWriter>:
  Identifiable,
  SQLiteDatabaseWriter,
  Sendable
{
  public let id: DatabaseIdentifier
  public let writer: Writer

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

  public func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await writer.read(body)
  }

  public func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try writer.readBlocking(body)
  }

  /// Writes to the database and announces the transaction it commits.
  ///
  /// A write that throws is rolled back by its writer and is not announced.
  public func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    let result = try await writer.write(body)
    reportLocalCommit()
    await Task { [self] in await announceCommittedTransaction() }.value
    return result
  }

  /// Writes to the database synchronously and announces the transaction it commits.
  ///
  /// The durable write completes before this method returns. Since IPC transports are
  /// asynchronous, its announcement continues in an independent task.
  public func writeBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    let result = try writer.writeBlocking(body)
    reportLocalCommit()
    Task { [self] in await announceCommittedTransaction() }
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
  /// Announcing outside the transaction matters: a peer that is told about a commit must be able to
  /// read it, and holding SQLite's write lock while waiting on a backpressured peer would turn one
  /// stalled process into a stalled database.
  ///
  /// The transaction is already durable, so a failed announcement never fails the write. The
  /// caller runs the broadcast in an unstructured `Task` rather than awaiting it directly: awaiting
  /// `transport.send` in-line would run it under the caller's own cancellation, so cancelling the
  /// write (e.g. its owning `Task`) could cut the announcement short even though peers still need to
  /// learn about a commit that already happened. A separate `Task` starts uncancelled, so it always
  /// runs to completion regardless of what the caller does afterward.
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
  public func subscribe(
    transactionObserver: any DatabaseTransactionObserver
  ) throws -> SQLiteCrossSubscription {
    let local = try writer.subscribe(transactionObserver: transactionObserver)
    let sameProcess = InterprocessDatabaseObservationHub.shared.subscribe(
      to: id,
      writerIdentifier: ObjectIdentifier(writer)
    ) {
      transactionObserver.databaseDidCommit(DatabaseCommit(origin: .local))
    }
    guard let transport else {
      return SQLiteCrossSubscription {
        local.cancel()
        sameProcess.cancel()
      }
    }

    do {
      let external = try transport.subscribe(to: id) { message in
        guard case .transactionDidCommit = message else { return }
        transactionObserver.databaseDidCommit(DatabaseCommit(origin: .external))
      }
      return SQLiteCrossSubscription {
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
/// process, and two wrappers around the same writer already share that writer's observer registry,
/// so registrations are keyed by both database and writer identity.
private final class InterprocessDatabaseObservationHub: Sendable {
  static let shared = InterprocessDatabaseObservationHub()

  private struct Registration: Sendable {
    let writerIdentifier: ObjectIdentifier
    let onCommit: @Sendable () -> Void
  }

  private struct State: Sendable {
    var nextIdentifier: UInt64 = 0
    var registrations = [DatabaseIdentifier: [UInt64: Registration]]()
  }

  private let state = Lock(State())

  func subscribe(
    to databaseIdentifier: DatabaseIdentifier,
    writerIdentifier: ObjectIdentifier,
    onCommit: @escaping @Sendable () -> Void
  ) -> SQLiteCrossSubscription {
    let identifier = state.withLock { state in
      let identifier = state.nextIdentifier
      state.nextIdentifier &+= 1
      state.registrations[databaseIdentifier, default: [:]][identifier] = Registration(
        writerIdentifier: writerIdentifier,
        onCommit: onCommit
      )
      return identifier
    }
    return SQLiteCrossSubscription { [weak self] in
      self?.remove(identifier: identifier, databaseIdentifier: databaseIdentifier)
    }
  }

  func didCommit(
    databaseIdentifier: DatabaseIdentifier,
    writerIdentifier: ObjectIdentifier
  ) {
    let callbacks = state.withLock { state in
      state.registrations[databaseIdentifier, default: [:]].values
        .compactMap { registration in
          registration.writerIdentifier == writerIdentifier ? nil : registration.onCommit
        }
    }
    for callback in callbacks { callback() }
  }

  private func remove(identifier: UInt64, databaseIdentifier: DatabaseIdentifier) {
    state.withLock { state in
      state.registrations[databaseIdentifier]?.removeValue(forKey: identifier)
      if state.registrations[databaseIdentifier]?.isEmpty == true {
        state.registrations.removeValue(forKey: databaseIdentifier)
      }
    }
  }
}
