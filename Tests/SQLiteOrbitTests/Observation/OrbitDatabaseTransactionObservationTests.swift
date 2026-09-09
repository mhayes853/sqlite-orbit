#if BuiltInSQLite
  import Foundation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct OrbitDatabaseTransactionObservationTests {
    @Test
    func localDriverReportsCommitLifecycleAndFinalTransactionState() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(
        observer.events == [
          .didChange(OrbitDatabaseRegion(table: "items")),
          .willCommit(1),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }

    @Test
    func bodyFailureReportsRollbackWithoutWillCommit() async throws {
      struct Abort: Error {}

      let driver = try SQLiteQueue(path: .memory)
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      await #expect(throws: Abort.self) {
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
          throw Abort()
        }
      }

      #expect(observer.events == [.didChange(.fullDatabase), .didRollback])
      _ = subscription
    }

    @Test
    func willCommitFailureAbortsTheWriteAndReportsRollback() async throws {
      struct Abort: Error {}

      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = FailingTransactionObserver(error: Abort())
      let subscription = try driver.subscribe(transactionObserver: observer)

      await #expect(throws: Abort.self) {
        try await driver.write { transaction in
          try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
        }
      }

      #expect(observer.didRollback)
      let count = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self))
      }
      #expect(count == 0)
      _ = subscription
    }

    @Test
    func cancellingSubscriptionStopsTransactionEvents() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)
      subscription.cancel()

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(observer.events.isEmpty)
    }

    @Test
    func readTransactionsPublishAutomaticCachedAndManualRegions() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute(
          "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
        )
        try transaction.execute("INSERT INTO items VALUES (1, 'One')")
      }
      let observer = ReadRecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)
      let automatic = OrbitDatabaseRegion(columns: ["id", "title"], in: "items")
      let manual = OrbitDatabaseRegion(table: "manual")

      try await driver.read { transaction in
        for _ in 0..<2 {
          _ = try transaction.fetchOne(
            #sql("SELECT title FROM items WHERE id = 1", as: String.self)
          )
        }
        _ = try transaction.fetchAll(#sql("SELECT title FROM items WHERE id = 1", as: String.self))
        _ = try transaction.fetchOne(#sql("PRAGMA user_version", as: Int.self))
        transaction.notifyReads(in: manual)
      }

      try await driver.write { transaction in
        transaction.notifyReads(in: manual)
      }

      #expect(
        observer.regions == [automatic, automatic, automatic, .fullDatabase, manual, manual]
      )
      _ = subscription
    }

    @Test
    func missingAuthorizerBroadensReadRegionsToTheFullDatabase() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE items (title TEXT NOT NULL);
          INSERT INTO items VALUES ('One');
          """
        )
      }
      let observer = ReadRecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      let explicitRegion = try await driver.read { transaction in
        let code = transaction.sqlite.set_authorizer(transaction.sqliteConnection, nil, nil)
        #expect(code == SQLiteResultCode.ok.rawValue)

        let region = try OrbitDatabaseRegion(QueryFragment("SELECT 1"), in: transaction)
        _ = try transaction.fetchOne(#sql("SELECT title FROM items", as: String.self))
        return region
      }

      #expect(explicitRegion == .fullDatabase)
      #expect(observer.regions == [.fullDatabase])
      _ = subscription
    }

    @Test
    func blockingWritesUseTheSameObserverLifecycle() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(
        observer.events == [
          .didChange(OrbitDatabaseRegion(table: "items")),
          .willCommit(1),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }

    @Test
    func poolWritesUseTheSameObserverLifecycle() async throws {
      let directory = try makeShortTemporaryDirectory("obs")
      defer { try? FileManager.default.removeItem(at: directory) }

      let driver = try SQLitePool(
        path: .file(directory.appending(component: "database.sqlite"))
      )
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(
        observer.events == [
          .didChange(OrbitDatabaseRegion(table: "items")),
          .willCommit(1),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }

    @Test
    func publishesEveryExplicitChangedRegion() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)
      let region = OrbitDatabaseRegion(column: "id", in: "items")

      try await driver.write { transaction in
        transaction.notifyChanges(in: region)
        transaction.notifyChanges(in: region)
      }

      #expect(
        observer.events == [
          .didChange(region),
          .didChange(region),
          .willCommit(0),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }

    @Test
    func automaticallyPublishesColumnAndTableChangedRegions() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute(
          "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT, isCompleted INTEGER)"
        )
        try transaction.execute("INSERT INTO items VALUES (1, 'Before', 0)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        _ = try transaction.fetchOne(#sql("SELECT title FROM items", as: String.self))
        try transaction.execute(
          "UPDATE items SET title = 'After', isCompleted = 1 WHERE id = 1"
        )
        try transaction.execute("DELETE FROM items")
      }

      let updatedColumns = OrbitDatabaseRegion(
        columns: ["title", "isCompleted"],
        in: "items"
      )
      #expect(
        observer.events == [
          .didChange(updatedColumns),
          .didChange(OrbitDatabaseRegion(table: "items")),
          .willCommit(0),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }

    @Test
    func updatesPublishWrittenAndGeneratedColumns() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE items (
            id INTEGER PRIMARY KEY,
            quantity INTEGER NOT NULL,
            doubled INTEGER GENERATED ALWAYS AS (quantity * 2),
            title TEXT
          );
          INSERT INTO items (id, quantity, title) VALUES (1, 1, 'One');
          """
        )
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        try transaction.execute("UPDATE items SET quantity = 2 WHERE id = 1")
      }

      #expect(
        observer.events == [
          .didChange(
            OrbitDatabaseRegion(
              columns: ["quantity", "doubled"],
              in: "items"
            )
          ),
          .willCommit(1),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }

    @Test
    func virtualTableUpdatesPublishTheWholeVirtualTable() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          CREATE VIRTUAL TABLE documents USING fts5(title);
          INSERT INTO documents VALUES ('Before');
          """
        )
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        try transaction.execute("UPDATE documents SET title = 'After'")
      }

      let changedRegions: [OrbitDatabaseRegion] = observer.events.compactMap { event in
        guard case .didChange(let region) = event else { return nil }
        return region
      }
      #expect(changedRegions.count == 1)
      #expect(
        changedRegions.first?
          .contains(
            OrbitDatabaseRegion(table: "documents")
          ) == true
      )
      #expect(
        observer.events.suffix(2) == [
          .willCommit(0),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }

    @Test
    func automaticRecompilationPublishesOnlyTheReplacementReadRegion() async throws {
      let directory = try makeShortTemporaryDirectory("obs")
      defer { try? FileManager.default.removeItem(at: directory) }

      let path = OrbitDatabasePath.file(directory.appendingPathComponent("db.sqlite"))
      do {
        let reader = try SQLiteQueue(path: path)
        let writer = try SQLiteQueue(path: path)
        try await writer.write { transaction in
          try transaction.execute(
            """
            CREATE TABLE original_items (title TEXT NOT NULL);
            CREATE TABLE alternate_items (title TEXT NOT NULL);
            INSERT INTO original_items VALUES ('Original');
            INSERT INTO alternate_items VALUES ('Alternate');
            CREATE VIEW current_items AS SELECT title FROM original_items;
            """
          )
        }
        let query = #sql("SELECT title FROM current_items", as: String.self)
        _ = try await reader.read { transaction in
          try transaction.fetchOne(query)
        }

        let observer = ReadRecordingTransactionObserver()
        let subscription = try reader.subscribe(transactionObserver: observer)
        try await writer.write { transaction in
          try transaction.execute(
            """
            DROP VIEW current_items;
            CREATE VIEW current_items AS SELECT title FROM alternate_items;
            """
          )
        }

        let value = try await reader.read { transaction in
          try transaction.fetchOne(query)
        }
        #expect(value == "Alternate")
        #expect(
          observer.regions == [
            OrbitDatabaseRegion(column: "title", in: "current_items")
              .union(OrbitDatabaseRegion(column: "title", in: "alternate_items"))
          ]
        )
        _ = subscription
      }
    }

    @Test
    func attachingADatabasePublishesNoChangedRegion() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        try transaction.execute("ATTACH DATABASE ':memory:' AS archive")
      }
      #expect(
        observer.events == [
          .willCommit(0),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }

    @Test
    func cachedWriteStatementsRetainTheirChangedRegion() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        for id in 1...2 {
          let query = OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(
            #sql("INSERT INTO items (id) VALUES (\(bind: id))", as: Void.self)
          )
          var cursor = try transaction.rowCursor(query, cached: true)
          while try cursor.next() != nil {}
        }
      }

      let table = OrbitDatabaseRegion(table: "items")
      #expect(
        observer.events == [
          .didChange(table),
          .didChange(table),
          .willCommit(2),
          .didCommit(.local)
        ]
      )
      _ = subscription
    }
  }

  private enum RecordedTransactionEvent: Equatable, Sendable {
    case didChange(OrbitDatabaseRegion)
    case willCommit(Int)
    case didCommit(OrbitDatabaseTransactionOrigin)
    case didRollback
  }

  private final class RecordingTransactionObserver: OrbitDatabaseTransactionObserver, Sendable {
    private let recordedEvents = Lock([RecordedTransactionEvent]())

    var events: [RecordedTransactionEvent] { recordedEvents.withLock { $0 } }

    func databaseDidChange(in region: OrbitDatabaseRegion) {
      recordedEvents.withLock { $0.append(.didChange(region)) }
    }

    func databaseWillCommit(
      _ transaction: borrowing SQLiteReadTransaction
    ) throws {
      let count = try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
      recordedEvents.withLock { $0.append(.willCommit(count)) }
    }

    func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
      recordedEvents.withLock { $0.append(.didCommit(commit.origin)) }
    }

    func databaseDidRollback() {
      recordedEvents.withLock { $0.append(.didRollback) }
    }
  }

  private final class ReadRecordingTransactionObserver:
    OrbitDatabaseTransactionObserver,
    Sendable
  {
    private let recordedRegions = Lock([OrbitDatabaseRegion]())

    var regions: [OrbitDatabaseRegion] { recordedRegions.withLock { $0 } }

    func databaseDidRead(in region: OrbitDatabaseRegion) {
      recordedRegions.withLock { $0.append(region) }
    }
  }

  private final class FailingTransactionObserver: OrbitDatabaseTransactionObserver, Sendable {
    private let error: any Error
    private let rollback = Lock(false)

    var didRollback: Bool { rollback.withLock { $0 } }

    init(error: any Error) {
      self.error = error
    }

    func databaseWillCommit(
      _ transaction: borrowing SQLiteReadTransaction
    ) throws {
      throw error
    }

    func databaseDidRollback() {
      rollback.withLock { $0 = true }
    }
  }
#endif
