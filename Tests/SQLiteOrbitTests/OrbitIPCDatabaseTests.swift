#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Foundation
    @testable import SQLiteOrbit
    import StructuredQueries
    import Testing

    @Suite
    struct OrbitIPCDatabaseAnnouncementTests {
      @Test(arguments: [false, true])
      func writeAnnouncesTheTransactionItCommits(blocking: Bool) async throws {
        let identifier = OrbitDatabaseIdentifier.unique()
        let delegate = RecordingOrbitIPCDatabaseDelegate()
        let (database, transport) = try makeAnnouncingDatabase(
          id: identifier,
          delegate: delegate
        )

        let createItems = #sql("CREATE TABLE items (id INTEGER)", as: Void.self)
        if blocking {
          try database.writeBlocking { try $0.execute(createItems) }
          // A blocking write announces on a task of its own, once it has returned.
          try await waitUntil { delegate.events.count == 2 }
        } else {
          try await database.write { try $0.execute(createItems) }
        }

        let message = OrbitIPCMessage.transactionDidCommit(
          .init(databaseIdentifier: identifier, region: .fullDatabase)
        )
        #expect(transport.messages == [message])
        #expect(
          delegate.events == [
            .willAnnounce(message),
            .didSuccessfullyAnnounce(message)
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
      func neitherAReadNorARolledBackWriteIsAnnounced() async throws {
        let (database, transport) = try makeAnnouncingDatabase()

        _ = try await database.read { transaction in
          try transaction.fetchAll(#sql("SELECT 1", as: Int.self))
        }
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
          delegate.events == [
            .willAnnounce(
              .transactionDidCommit(.init(databaseIdentifier: database.id, region: .empty))
            ),
            .didFailToAnnounce(
              .transactionDidCommit(.init(databaseIdentifier: database.id, region: .empty)),
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
        #expect(
          delegate.events == [
            .willAnnounce(transport.messages[0]),
            .didSuccessfullyAnnounce(transport.messages[0])
          ]
        )
      }

      @Test
      func announcementUsesOneDelegateSnapshot() async throws {
        let originalDelegate = RecordingOrbitIPCDatabaseDelegate()
        let replacementDelegate = RecordingOrbitIPCDatabaseDelegate()
        let (database, transport) = try makeAnnouncingDatabase(
          delay: .milliseconds(50),
          delegate: originalDelegate
        )

        let write = Task {
          try await database.write { transaction in
            try transaction.execute(#sql("CREATE TABLE items (id INTEGER)", as: Void.self))
          }
        }
        try await waitUntil { transport.didBeginSending }
        database.delegate = replacementDelegate
        try await write.value

        #expect(
          originalDelegate.events == [
            .willAnnounce(transport.messages[0]),
            .didSuccessfullyAnnounce(transport.messages[0])
          ]
        )
        #expect(replacementDelegate.events.isEmpty)
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
        let observer = TransactionEventRecorder()
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
        let observer = TransactionEventRecorder()

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

      @Test(arguments: [false, true])
      func siblingHandleReportsARegionBeforeItsOneLocalCommit(withoutTransaction: Bool) async throws
      {
        let identifier = OrbitDatabaseIdentifier.unique()
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
        let observer = TransactionEventRecorder()
        let subscription = try observingDatabase.subscribe(transactionObserver: observer)
        let region = OrbitDatabaseRegion(table: "items")

        if withoutTransaction {
          try await writingDatabase.writeWithoutTransaction { $0.notifyChanges(in: region) }
        } else {
          try await writingDatabase.write { $0.notifyChanges(in: region) }
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

      @Test(arguments: [false, true])
      func writeWithoutTransactionThatThrowsAnnouncesWhatCommittedBeforeTheFailure(
        blocking: Bool
      ) async throws {
        let identifier = OrbitDatabaseIdentifier.unique()
        let (database, transport) = try makeAnnouncingDatabase(id: identifier)
        try await createAnnouncementTables(in: database)
        transport.removeAllMessages()
        let body: @Sendable (borrowing SQLiteWriteConnection) throws -> Void = { connection in
          try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          try connection.transaction { transaction in
            try transaction.execute(#sql("INSERT INTO lists (id) VALUES (1)", as: Void.self))
          }
          throw WriteFailure()
        }

        if blocking {
          #expect(throws: WriteFailure.self) { try database.writeWithoutTransactionBlocking(body) }
          try await waitUntil { transport.messages.count == 1 }
        } else {
          await #expect(throws: WriteFailure.self) {
            try await database.writeWithoutTransaction(body)
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
        let received = IPCMessageRecorder()
        let subscription = try peerTransport.subscribe(to: identifier, onMessage: received.append)

        try await database.writeWithoutTransaction { connection in
          try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          try connection.execute(#sql("INSERT INTO lists (id) VALUES (1)", as: Void.self))
        }

        let committed = OrbitDatabaseRegion(table: "items")
          .union(OrbitDatabaseRegion(table: "lists"))
        #expect(
          received.values == [
            .transactionDidCommit(.init(databaseIdentifier: identifier, region: committed))
          ]
        )
        _ = subscription
      }

    }

    private func createAnnouncementTables(in database: OrbitIPCDatabase) async throws {
      try await database.write { transaction in
        try transaction.executeScript(
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
      func recorderKeepsCommittedRegionsApartFromAllProvisionalChanges() {
        let context = SQLiteConnectionEvents()
        let recorder = OrbitDatabaseRegionRecorder()
        let observers = OrbitDatabaseTransactionObservers()
        let subscription = observers.subscribe(recorder)
        let committed = OrbitDatabaseRegion(table: "committed")
        let rolledBack = OrbitDatabaseRegion(table: "rolled_back")
        let autocommitted = OrbitDatabaseRegion(table: "autocommitted")
        let pending = OrbitDatabaseRegion(table: "pending")

        context.withObservation(observers) {
          context.didChange(in: committed)
          context.didCommit()
          context.didChange(in: rolledBack)
          context.didRollback()
          context.didChange(in: autocommitted)
          context.didCommitPendingChanges()
          context.didChange(in: pending)
        }

        #expect(recorder.committedRegion == committed.union(autocommitted))
        #expect(
          recorder.changedRegion == committed.union(autocommitted).union(rolledBack).union(pending)
        )
        _ = subscription
      }

      @Test
      func recorderMissesTheEventsOfTransactionsEndingAfterItsScope() {
        let context = SQLiteConnectionEvents()
        let recorder = OrbitDatabaseRegionRecorder()
        let observers = OrbitDatabaseTransactionObservers()
        let subscription = observers.subscribe(recorder)
        let region = OrbitDatabaseRegion(table: "items")

        context.withObservation(observers) {
          context.didChange(in: region)
        }
        context.didRollback()

        #expect(recorder.committedRegion == .empty)
        #expect(recorder.changedRegion == region)
        _ = subscription
      }
    }

    private func makeAnnouncingDatabase(
      id: OrbitDatabaseIdentifier? = nil,
      failure: (any Error)? = nil,
      delay: Duration? = nil,
      delegate: (any OrbitIPCDatabase.Delegate)? = nil
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

    private enum RecordedAnnouncementEvent: Equatable, Sendable {
      case willAnnounce(OrbitIPCMessage)
      case didSuccessfullyAnnounce(OrbitIPCMessage)
      case didFailToAnnounce(OrbitIPCMessage, errorType: String)
    }

    private final class RecordingOrbitIPCDatabaseDelegate: OrbitIPCDatabase.Delegate, Sendable {
      private let recordedEvents = Lock([RecordedAnnouncementEvent]())

      var events: [RecordedAnnouncementEvent] { recordedEvents.withLock { $0 } }

      func orbitIPCDatabase(
        _ database: OrbitIPCDatabase,
        willAnnounce message: OrbitIPCMessage
      ) {
        recordedEvents.withLock { $0.append(.willAnnounce(message)) }
      }

      func orbitIPCDatabase(
        _ database: OrbitIPCDatabase,
        didSuccessfullyAnnounce message: OrbitIPCMessage
      ) {
        recordedEvents.withLock { $0.append(.didSuccessfullyAnnounce(message)) }
      }

      func orbitIPCDatabase(
        _ database: OrbitIPCDatabase,
        didFailToAnnounce message: OrbitIPCMessage,
        error: any Error
      ) {
        recordedEvents.withLock {
          $0.append(.didFailToAnnounce(message, errorType: "\(type(of: error))"))
        }
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
        region: OrbitDatabaseRegion,
        onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
      ) throws -> OrbitRegionSubscription {
        if rejectsSubscriptions { throw AnnouncementFailure() }
        return OrbitRegionSubscription(region: region) {}
      }

      func send(_ message: OrbitIPCMessage) async throws {
        self.state.withLock { $0.didBeginSending = true }
        if let delay = self.delay { try await Task.sleep(for: delay) }
        self.state.withLock { $0.messages.append(message) }
        if let failure = self.failure { throw failure }
      }
    }
  #endif
#endif
