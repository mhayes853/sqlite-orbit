#if GRDB
  import Foundation
  import GRDB
  import SQLiteCross
  import StructuredQueries
  import Synchronization
  import Testing

  @Suite
  struct CrossProcessDatabaseAnnouncementTests {
    @Test
    func writeAnnouncesTheTransactionItCommits() async throws {
      let identifier = DatabaseIdentifier(rawValue: "announced")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)

      try await database.write { transaction in
        try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
      }

      #expect(
        transport.messages == [.transactionDidCommit(.init(databaseIdentifier: identifier))]
      )
    }

    @Test
    func readIsNotAnnounced() async throws {
      let (database, transport) = try makeAnnouncingDatabase()

      _ = try await database.read { transaction in
        try transaction.fetchAll(#sql("SELECT 1", as: Int.self))
      }

      #expect(transport.messages.isEmpty)
    }

    @Test
    func rolledBackWriteIsNotAnnounced() async throws {
      let (database, transport) = try makeAnnouncingDatabase()

      await #expect(throws: WriteFailure.self) {
        try await database.write { _ in throw WriteFailure() }
      }

      #expect(transport.messages.isEmpty)
    }

    @Test
    func announcementIsSentOnlyAfterTheWriteTransactionCommits() async throws {
      let (database, transport) = try makeAnnouncingDatabase()
      let announcementsDuringWrite = Mutex(-1)

      try await database.write { transaction in
        try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
        announcementsDuringWrite.withLock { $0 = transport.messages.count }
      }

      #expect(announcementsDuringWrite.withLock { $0 } == 0)
      #expect(transport.messages.count == 1)
    }

    @Test
    func failedAnnouncementDoesNotFailTheWriteItFollows() async throws {
      let failures = Mutex([String]())
      let (database, _) = try makeAnnouncingDatabase(
        failure: AnnouncementFailure(),
        onAnnouncementFailure: { error in failures.withLock { $0.append("\(type(of: error))") } }
      )

      let value = try await database.write { transaction in
        try transaction.fetchAll(#sql("SELECT 1", as: Int.self))
      }

      #expect(value == [1])
      #expect(failures.withLock { $0 } == ["AnnouncementFailure"])
    }

    @Test
    func announcementIsNotCancelledAlongWithTheWritingTask() async throws {
      // The transaction is already durable once the announcement starts, so cancelling the writer
      // must not stop peers from being told about a commit that happened.
      let failures = Mutex(0)
      let (database, transport) = try makeAnnouncingDatabase(
        delay: .milliseconds(50),
        onAnnouncementFailure: { _ in failures.withLock { $0 += 1 } }
      )

      let write = Task {
        try await database.write { transaction in
          try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
        }
      }
      try await waitUntil { transport.didBeginSending }
      write.cancel()
      try await write.value

      #expect(transport.messages.count == 1)
      #expect(failures.withLock { $0 } == 0)
    }
  }

  private func makeAnnouncingDatabase(
    id: DatabaseIdentifier? = nil,
    failure: (any Error)? = nil,
    delay: Duration? = nil,
    onAnnouncementFailure: (@Sendable (any Error) -> Void)? = nil
  ) throws -> (CrossProcessDatabase<GRDBDatabaseDriver>, RecordingDatabaseIPCTransport) {
    let transport = RecordingDatabaseIPCTransport(failure: failure, delay: delay)
    let database = try CrossProcessDatabase(
      writer: DatabaseQueue(),
      id: id,
      transport: transport,
      onAnnouncementFailure: onAnnouncementFailure
    )
    return (database, transport)
  }

  private struct WriteFailure: Error {}
  private struct AnnouncementFailure: Error {}

  /// Records what a database announces without reaching another process.
  private final class RecordingDatabaseIPCTransport: DatabaseIPCTransport, Sendable {
    private struct State {
      var messages = [DatabaseIPCMessage]()
      var didBeginSending = false
    }

    private let state = Mutex(State())
    private let failure: (any Error)?
    private let delay: Duration?

    var messages: [DatabaseIPCMessage] { self.state.withLock { $0.messages } }
    var didBeginSending: Bool { self.state.withLock { $0.didBeginSending } }

    init(failure: (any Error)? = nil, delay: Duration? = nil) {
      self.failure = failure
      self.delay = delay
    }

    func subscribe(
      to databaseIdentifier: DatabaseIdentifier,
      onMessage: @escaping @Sendable (DatabaseIPCMessage) -> Void
    ) throws -> SQLiteCrossSubscription {
      SQLiteCrossSubscription {}
    }

    func send(_ message: DatabaseIPCMessage) async throws {
      self.state.withLock { $0.didBeginSending = true }
      if let delay = self.delay { try await Task.sleep(for: delay) }
      self.state.withLock { $0.messages.append(message) }
      if let failure = self.failure { throw failure }
    }
  }
#endif
