#if BuiltInSQLite
  import Foundation
  @testable import SQLiteOrbit
  import StructuredQueries
  import Testing

  @Suite
  struct OrbitIPCDatabaseAnnouncementTests {
    @Test
    func writeAnnouncesTheTransactionItCommits() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "announced")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)

      try await database.write { transaction in
        try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
      }

      #expect(
        transport.messages == [
          .transactionDidCommit(.init(databaseIdentifier: identifier, region: .fullDatabase))
        ]
      )
    }

    @Test
    func blockingWriteAnnouncesTheTransactionItCommits() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "blocking-announcement")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)

      try database.writeBlocking { transaction in
        try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
      }
      try await waitUntil { transport.messages.count == 1 }

      #expect(
        transport.messages == [
          .transactionDidCommit(.init(databaseIdentifier: identifier, region: .fullDatabase))
        ]
      )
    }

    @Test
    func writeAnnouncesTheUnionOfItsChangedRegions() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "region-announcement")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)
      let title = OrbitDatabaseRegion(column: "title", in: "items")
      let archived = OrbitDatabaseRegion(table: "archived", schema: "archive")

      try await database.write { transaction in
        transaction.notifyChanges(in: title)
        transaction.notifyChanges(in: archived)
        transaction.notifyChanges(in: title)
      }

      #expect(
        transport.messages == [
          .transactionDidCommit(
            .init(databaseIdentifier: identifier, region: title.union(archived))
          )
        ]
      )
    }

    @Test
    func writeAnnouncesAnEmptyRegionWhenNothingChanged() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "empty-region-announcement")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)

      _ = try await database.write { transaction in
        try transaction.fetchAll(#sql("SELECT 1", as: Int.self))
      }

      #expect(
        transport.messages == [
          .transactionDidCommit(.init(databaseIdentifier: identifier, region: .empty))
        ]
      )
    }

    @Test
    func writeAnnouncesAutomaticallyTrackedColumns() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "automatic-region-announcement")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)
      try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT, isCompleted INTEGER)"
        )
        try transaction.execute("INSERT INTO items VALUES (1, 'Before', 0)")
      }
      transport.removeAllMessages()

      try await database.write { transaction in
        try transaction.execute(
          "UPDATE items SET title = 'After', isCompleted = 1 WHERE id = 1"
        )
      }

      #expect(
        transport.messages == [
          .transactionDidCommit(
            .init(
              databaseIdentifier: identifier,
              region: OrbitDatabaseRegion(columns: ["title", "isCompleted"], in: "items")
            )
          )
        ]
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
      let announcementsDuringWrite = Lock(-1)

      try await database.write { transaction in
        try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
        announcementsDuringWrite.withLock { $0 = transport.messages.count }
      }

      #expect(announcementsDuringWrite.withLock { $0 } == 0)
      #expect(transport.messages.count == 1)
    }

    @Test
    func failedAnnouncementDoesNotFailTheWriteItFollows() async throws {
      let delegate = RecordingOrbitIPCDatabaseDelegate()
      let (database, _) = try makeAnnouncingDatabase(
        failure: AnnouncementFailure(),
        delegate: delegate
      )

      let value = try await database.write { transaction in
        try transaction.fetchAll(#sql("SELECT 1", as: Int.self))
      }

      #expect(value == [1])
      #expect(
        delegate.failures == [
          .init(
            message: .transactionDidCommit(
              .init(databaseIdentifier: database.id, region: .empty)
            ),
            errorType: "AnnouncementFailure"
          )
        ]
      )
    }

    @Test
    func announcementIsNotCancelledAlongWithTheWritingTask() async throws {
      // The transaction is already durable once the announcement starts, so cancelling the writer
      // must not stop peers from being told about a commit that happened.
      let delegate = RecordingOrbitIPCDatabaseDelegate()
      let (database, transport) = try makeAnnouncingDatabase(
        delay: .milliseconds(50),
        delegate: delegate
      )

      let write = Task {
        try await database.write { transaction in
          try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
        }
      }
      try await waitUntil { transport.didBeginSending }
      write.cancel()
      _ = try await write.value

      #expect(transport.messages.count == 1)
      #expect(delegate.failures.isEmpty)
    }

    @Test
    func databaseHoldsItsDelegateWeakly() throws {
      let (database, _) = try makeAnnouncingDatabase()
      var delegate: RecordingOrbitIPCDatabaseDelegate? = .init()
      weak let weakDelegate = delegate

      database.delegate = delegate
      #expect(database.delegate === delegate)
      delegate = nil

      #expect(weakDelegate == nil)
      #expect(database.delegate == nil)
    }

    @Test
    func externalAnnouncementReportsItsRegionBeforeItsCommit() async throws {
      let network = InMemoryIPCTransport.Network()
      let receivingTransport = InMemoryIPCTransport(network: network)
      let sendingTransport = InMemoryIPCTransport(network: network)
      let identifier = OrbitDatabaseIdentifier(rawValue: "external-region")
      let database = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: receivingTransport
      )
      let observer = RecordingPeerTransactionObserver()
      let subscription = try database.subscribe(transactionObserver: observer)
      let region = OrbitDatabaseRegion(column: "title", in: "items")

      try await sendingTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier, region: region))
      )

      #expect(observer.events == [.didChange(region), .didCommit(.external)])
      _ = subscription
    }

    @Test
    func failedTransportSubscriptionRemovesLocalAndSiblingObservers() async throws {
      let identifier = OrbitDatabaseIdentifier.unique()
      let database = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: RecordingDatabaseIPCTransport(rejectsSubscriptions: true)
      )
      let sibling = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: InMemoryIPCTransport()
      )
      let observer = RecordingPeerTransactionObserver()

      #expect(throws: AnnouncementFailure.self) {
        try database.subscribe(transactionObserver: observer)
      }
      for writer in [database, sibling] {
        try await writer.write { transaction in
          transaction.notifyChanges(in: OrbitDatabaseRegion(table: "items"))
        }
      }

      #expect(observer.events.isEmpty)
    }

    @Test
    func siblingHandleReportsItsRegionBeforeItsCommit() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "sibling-region")
      let writingDatabase = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: InMemoryIPCTransport()
      )
      let observingDatabase = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: InMemoryIPCTransport()
      )
      let observer = RecordingPeerTransactionObserver()
      let subscription = try observingDatabase.subscribe(transactionObserver: observer)
      let region = OrbitDatabaseRegion(table: "items")

      try await writingDatabase.write { transaction in
        transaction.notifyChanges(in: region)
      }

      #expect(observer.events == [.didChange(region), .didCommit(.local)])
      _ = subscription
    }

    @Test
    func writeWithoutTransactionAnnouncesTheUnionOfWhatCommittedOnce() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "without-transaction-announcement")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)
      try await createAnnouncementTables(in: database)
      transport.removeAllMessages()

      try await database.writeWithoutTransaction { connection in
        try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
        try connection.transaction { transaction in
          try transaction.execute(#sql("INSERT INTO lists (id) VALUES (1)", as: Void.self))
        }
        try? connection.transaction { transaction in
          try transaction.execute(#sql("INSERT INTO archive (id) VALUES (1)", as: Void.self))
          throw WriteFailure()
        }
      }

      let committed = OrbitDatabaseRegion(table: "items")
        .union(OrbitDatabaseRegion(table: "lists"))
      #expect(
        transport.messages == [
          .transactionDidCommit(.init(databaseIdentifier: identifier, region: committed))
        ]
      )
    }

    @Test
    func writeWithoutTransactionThatThrowsAnnouncesWhatCommittedBeforeTheFailure() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "without-transaction-failure")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)
      try await createAnnouncementTables(in: database)
      transport.removeAllMessages()

      await #expect(throws: WriteFailure.self) {
        try await database.writeWithoutTransaction { connection in
          try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          try connection.transaction { transaction in
            try transaction.execute(#sql("INSERT INTO lists (id) VALUES (1)", as: Void.self))
          }
          throw WriteFailure()
        }
      }

      let committed = OrbitDatabaseRegion(table: "items")
        .union(OrbitDatabaseRegion(table: "lists"))
      #expect(
        transport.messages == [
          .transactionDidCommit(.init(databaseIdentifier: identifier, region: committed))
        ]
      )
    }

    @Test
    func writeWithoutTransactionThatCommitsNothingIsNotAnnounced() async throws {
      let (database, transport) = try makeAnnouncingDatabase()
      try await createAnnouncementTables(in: database)
      transport.removeAllMessages()

      try await database.writeWithoutTransaction { connection in
        try connection.execute("PRAGMA foreign_keys = OFF")
        try connection.execute("PRAGMA foreign_keys = ON")
        _ = try connection.fetchAll(#sql("SELECT id FROM items", as: Int.self))
        try? connection.transaction { transaction in
          try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          throw WriteFailure()
        }
      }
      await #expect(throws: WriteFailure.self) {
        try await database.writeWithoutTransaction { _ in throw WriteFailure() }
      }
      try database.writeWithoutTransactionBlocking { _ in }
      _ = try await database.readWithoutTransaction { connection in
        try connection.fetchAll(#sql("SELECT id FROM items", as: Int.self))
      }

      #expect(transport.messages.isEmpty)
    }

    @Test
    func blockingWriteWithoutTransactionAnnouncesWhatCommittedWhenItThrows() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "blocking-without-transaction")
      let (database, transport) = try makeAnnouncingDatabase(id: identifier)
      try await createAnnouncementTables(in: database)
      transport.removeAllMessages()

      #expect(throws: WriteFailure.self) {
        try database.writeWithoutTransactionBlocking { connection in
          try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          throw WriteFailure()
        }
      }
      try await waitUntil { transport.messages.count == 1 }

      #expect(
        transport.messages == [
          .transactionDidCommit(
            .init(databaseIdentifier: identifier, region: OrbitDatabaseRegion(table: "items"))
          )
        ]
      )
    }

    @Test
    func peerReceivesOneAnnouncementForAWriteWithoutTransaction() async throws {
      let network = InMemoryIPCTransport.Network()
      let identifier = OrbitDatabaseIdentifier(rawValue: "without-transaction-peer")
      let database = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: InMemoryIPCTransport(network: network)
      )
      try await createAnnouncementTables(in: database)
      let peerTransport = InMemoryIPCTransport(network: network)
      let received = Lock([OrbitIPCMessage]())
      let subscription = try peerTransport.subscribe(to: identifier) { message in
        received.withLock { $0.append(message) }
      }

      try await database.writeWithoutTransaction { connection in
        try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
        try connection.execute(#sql("INSERT INTO lists (id) VALUES (1)", as: Void.self))
      }

      let committed = OrbitDatabaseRegion(table: "items")
        .union(OrbitDatabaseRegion(table: "lists"))
      #expect(
        received.withLock { $0 } == [
          .transactionDidCommit(.init(databaseIdentifier: identifier, region: committed))
        ]
      )
      _ = subscription
    }

    @Test
    func siblingHandleSeesWriteWithoutTransactionAsOneLocalCommit() async throws {
      let identifier = OrbitDatabaseIdentifier(rawValue: "without-transaction-sibling")
      let writingDatabase = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: InMemoryIPCTransport()
      )
      let observingDatabase = OrbitIPCDatabase(
        writer: try SQLiteQueue(path: .memory),
        id: identifier,
        transport: InMemoryIPCTransport()
      )
      let observer = RecordingPeerTransactionObserver()
      let subscription = try observingDatabase.subscribe(transactionObserver: observer)
      let region = OrbitDatabaseRegion(table: "items")

      try await writingDatabase.writeWithoutTransaction { connection in
        connection.notifyChanges(in: region)
      }

      #expect(observer.events == [.didChange(region), .didCommit(.local)])
      _ = subscription
    }
  }

  private func createAnnouncementTables(in database: OrbitIPCDatabase) async throws {
    try await database.write { transaction in
      try transaction.execute(
        """
        CREATE TABLE items (id INTEGER PRIMARY KEY);
        CREATE TABLE lists (id INTEGER PRIMARY KEY);
        CREATE TABLE archive (id INTEGER PRIMARY KEY);
        """
      )
    }
  }

  @Suite
  struct OrbitDatabaseRegionRecorderTests {
    @Test
    func recorderKeepsCommittedRegionsApartFromRolledBackAndPendingOnes() {
      let context = OrbitDatabaseTransactionObservationContext(databaseObservers: nil)
      let recorder = OrbitDatabaseRegionRecorder()
      let committed = OrbitDatabaseRegion(table: "committed")
      let rolledBack = OrbitDatabaseRegion(table: "rolled_back")
      let autocommitted = OrbitDatabaseRegion(table: "autocommitted")
      let pending = OrbitDatabaseRegion(table: "pending")

      context.withObserver(recorder) {
        context.didChange(in: committed)
        context.didCommit(origin: .local)
        context.didChange(in: rolledBack)
        context.didRollback()
        context.didChange(in: autocommitted)
        context.didCommitPendingChanges()
        context.didChange(in: pending)
      }

      #expect(recorder.committedRegion == committed.union(autocommitted))
      #expect(recorder.changedRegion == committed.union(autocommitted).union(pending))
    }

    @Test
    func recorderMissesTheEventsOfTransactionsEndingAfterItsScope() {
      let context = OrbitDatabaseTransactionObservationContext(databaseObservers: nil)
      let recorder = OrbitDatabaseRegionRecorder()
      let region = OrbitDatabaseRegion(table: "items")

      context.withObserver(recorder) {
        context.didChange(in: region)
      }
      context.didRollback()

      #expect(recorder.committedRegion == .empty)
      #expect(recorder.changedRegion == region)
    }
  }

  private func makeAnnouncingDatabase(
    id: OrbitDatabaseIdentifier? = nil,
    failure: (any Error)? = nil,
    delay: Duration? = nil,
    delegate: (any OrbitIPCDatabaseDelegate)? = nil
  ) throws -> (OrbitIPCDatabase, RecordingDatabaseIPCTransport) {
    let transport = RecordingDatabaseIPCTransport(failure: failure, delay: delay)
    let database = OrbitIPCDatabase(
      writer: try SQLiteQueue(path: ":memory:"),
      id: id,
      transport: transport,
      delegate: delegate
    )
    return (database, transport)
  }

  private struct WriteFailure: Error {}
  private struct AnnouncementFailure: Error {}

  private struct RecordedAnnouncementFailure: Equatable, Sendable {
    let message: OrbitIPCMessage
    let errorType: String
  }

  private final class RecordingOrbitIPCDatabaseDelegate: OrbitIPCDatabaseDelegate, Sendable {
    private let recordedFailures = Lock([RecordedAnnouncementFailure]())

    var failures: [RecordedAnnouncementFailure] { recordedFailures.withLock { $0 } }

    func orbitIPCDatabase(
      _ database: OrbitIPCDatabase,
      didFailToAnnounce message: OrbitIPCMessage,
      error: any Error
    ) {
      recordedFailures.withLock {
        $0.append(.init(message: message, errorType: "\(type(of: error))"))
      }
    }
  }

  private enum RecordedPeerTransactionEvent: Equatable, Sendable {
    case didChange(OrbitDatabaseRegion)
    case didCommit(OrbitDatabaseTransactionOrigin)
  }

  private final class RecordingPeerTransactionObserver:
    OrbitDatabaseTransactionObserver,
    Sendable
  {
    private let recordedEvents = Lock([RecordedPeerTransactionEvent]())

    var events: [RecordedPeerTransactionEvent] { recordedEvents.withLock { $0 } }

    func databaseDidChange(in region: OrbitDatabaseRegion) {
      recordedEvents.withLock { $0.append(.didChange(region)) }
    }

    func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
      recordedEvents.withLock { $0.append(.didCommit(commit.origin)) }
    }
  }

  private final class RecordingDatabaseIPCTransport: OrbitIPCTransport, Sendable {
    private struct State {
      var messages = [OrbitIPCMessage]()
      var didBeginSending = false
    }

    private let state = Lock(State())
    private let failure: (any Error)?
    private let delay: Duration?
    private let rejectsSubscriptions: Bool

    var messages: [OrbitIPCMessage] { self.state.withLock { $0.messages } }
    var didBeginSending: Bool { self.state.withLock { $0.didBeginSending } }

    func removeAllMessages() {
      self.state.withLock { $0.messages.removeAll() }
    }

    init(
      failure: (any Error)? = nil,
      delay: Duration? = nil,
      rejectsSubscriptions: Bool = false
    ) {
      self.failure = failure
      self.delay = delay
      self.rejectsSubscriptions = rejectsSubscriptions
    }

    func subscribe(
      to databaseIdentifier: OrbitDatabaseIdentifier,
      onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
    ) throws -> OrbitSubscription {
      if rejectsSubscriptions { throw AnnouncementFailure() }
      return OrbitSubscription {}
    }

    func send(_ message: OrbitIPCMessage) async throws {
      self.state.withLock { $0.didBeginSending = true }
      if let delay = self.delay { try await Task.sleep(for: delay) }
      self.state.withLock { $0.messages.append(message) }
      if let failure = self.failure { throw failure }
    }
  }
#endif
