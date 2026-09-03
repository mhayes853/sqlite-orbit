/// The public database handle that coordinates local transactions with other processes.
///
/// A database announces every write it commits so that processes sharing the same SQLite file can
/// react to each other's work. It does not yet subscribe to its peers; observation will be layered
/// on without changing the writer-facing transaction model.
public final class InterprocessDatabase<Writer: SQLiteDatabaseWriter>: Identifiable, Sendable {
  public let id: DatabaseIdentifier
  public let writer: Writer

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

  /// Writes to the database and announces the transaction it commits.
  ///
  /// A write that throws is rolled back by its writer and is not announced.
  public func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    let result = try await writer.write(body)
    await announceCommittedTransaction()
    return result
  }

  /// Announces a committed write once the writer has released its write transaction.
  ///
  /// Announcing outside the transaction matters: a peer that is told about a commit must be able to
  /// read it, and holding SQLite's write lock while waiting on a backpressured peer would turn one
  /// stalled process into a stalled database.
  ///
  /// The transaction is already durable, so a failed announcement never fails the write. The
  /// broadcast also runs in its own unstructured `Task` rather than being awaited directly: awaiting
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
      try await Task { try await transport.send(message) }.value
    } catch {
      onAnnouncementFailure?(error)
    }
  }
}
