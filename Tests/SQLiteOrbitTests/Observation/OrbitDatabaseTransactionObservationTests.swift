#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Foundation
    import StructuredQueriesSQLite
    import Testing

    @testable import SQLiteOrbit

    @Suite
    struct OrbitDatabaseTransactionObservationTests {
      @Test(arguments: LifecycleWrite.allCases)
      func aWriteReportsCommitLifecycleAndFinalTransactionState(_ write: LifecycleWrite)
        async throws
      {
        try await withTestDatabaseFile("obs") { file in
          let driver: any OrbitObservableDatabase =
            write == .pool ? try file.pool() : try SQLiteQueue(path: .memory)
          try await driver.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
          let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
          let subscription = try driver.subscribe(transactionObserver: observer)

          if write == .blocking {
            try driver.writeBlocking { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
            }
          } else {
            try await driver.write { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
            }
          }

          #expect(
            observer.events == [
              .didChange(OrbitDatabaseRegion(table: "items")),
              .willCommit(1),
              .didCommit(.local)
            ]
          )
          #expect(
            observer.commits == [
              OrbitDatabaseCommit(
                origin: .local,
                region: OrbitDatabaseRegion(table: "items")
              )
            ]
          )
          _ = subscription
        }
      }

      @Test
      func bodyFailureReportsRollbackWithoutWillCommit() async throws {
        let driver = try SQLiteQueue(path: .memory)
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let subscription = try driver.subscribe(transactionObserver: observer)

        await #expect(throws: TestError.self) {
          try await driver.write { transaction in
            try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
            throw TestError()
          }
        }

        #expect(observer.events == [.didChange(.fullDatabase), .didRollback])
        _ = subscription
      }

      @Test
      func willCommitFailureAbortsTheWriteAndReportsRollback() async throws {
        let driver = try await itemsDatabase()
        let observer = TransactionEventRecorder()
        let subscriptions = try [
          driver.subscribe(transactionObserver: observer),
          driver.subscribe(transactionObserver: TransactionEventRecorder(commitError: TestError()))
        ]

        await #expect(throws: TestError.self) {
          try await driver.write { transaction in
            try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          }
        }

        #expect(observer.events == [.didChange(OrbitDatabaseRegion(table: "items")), .didRollback])
        #expect(try await driver.rowCount(of: "items") == 0)
        _ = subscriptions
      }

      @Test
      func cancellingSubscriptionStopsTransactionEvents() async throws {
        let driver = try await itemsDatabase()
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
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
        let observer = TransactionEventRecorder()
        let subscription = try driver.subscribe(transactionObserver: observer)
        let automatic = OrbitDatabaseRegion(columns: ["id", "title"], in: "items")
        let manual = OrbitDatabaseRegion(table: "manual")

        try await driver.read { transaction in
          for _ in 0..<2 {
            _ = try transaction.fetchOne(
              #sql("SELECT title FROM items WHERE id = 1", as: String.self)
            )
          }
          _ = try transaction.fetchAll(
            #sql("SELECT title FROM items WHERE id = 1", as: String.self)
          )
          _ = try transaction.fetchOne(#sql("PRAGMA user_version", as: Int.self))
          transaction.notifyReads(in: manual)
        }

        try await driver.write { transaction in
          transaction.notifyReads(in: manual)
        }

        #expect(
          observer.readRegions == [automatic, automatic, automatic, .fullDatabase, manual, manual]
        )
        _ = subscription
      }

      @Test
      func missingAuthorizerBroadensReadRegionsToTheFullDatabase() async throws {
        let driver = try SQLiteQueue(path: .memory)
        try await driver.execute(
          sql: """
            CREATE TABLE items (title TEXT NOT NULL);
            INSERT INTO items VALUES ('One');
            """
        )
        let observer = TransactionEventRecorder()
        let subscription = try driver.subscribe(transactionObserver: observer)

        let explicitRegion = try await driver.read { transaction in
          let code = transaction.sqlite.authorizer!.install(transaction.sqliteConnection, nil, nil)
          #expect(code == SQLiteResultCode.ok.rawValue)

          let region = try OrbitDatabaseRegion("SELECT 1", in: transaction)
          _ = try transaction.fetchOne(#sql("SELECT title FROM items", as: String.self))
          return region
        }

        #expect(explicitRegion == .fullDatabase)
        #expect(observer.readRegions == [.fullDatabase])
        _ = subscription
      }

      @Test
      func publishesEveryExplicitChangedRegion() async throws {
        let driver = try await itemsDatabase()
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
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
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
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
        try await driver.execute(
          sql: """
            CREATE TABLE items (
              id INTEGER PRIMARY KEY,
              quantity INTEGER NOT NULL,
              doubled INTEGER GENERATED ALWAYS AS (quantity * 2),
              title TEXT
            );
            INSERT INTO items (id, quantity, title) VALUES (1, 1, 'One');
            """
        )
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let subscription = try driver.subscribe(transactionObserver: observer)

        try await driver.execute(sql: "UPDATE items SET quantity = 2 WHERE id = 1")

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
        try await driver.execute(
          sql: """
            CREATE TABLE items (id INTEGER PRIMARY KEY);
            CREATE VIRTUAL TABLE documents USING fts5(title);
            INSERT INTO documents VALUES ('Before');
            """
        )
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let subscription = try driver.subscribe(transactionObserver: observer)

        try await driver.execute(sql: "UPDATE documents SET title = 'After'")

        #expect(observer.changedRegions.count == 1)
        #expect(
          observer.changedRegions.first?.contains(OrbitDatabaseRegion(table: "documents")) == true
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
        try await withTestDatabaseFile("obs") { file in
          let reader = try file.queue()
          let writer = try file.queue()
          try await writer.execute(sql: currentItemsViewSchema)
          let query = #sql("SELECT title FROM current_items", as: String.self)
          _ = try await reader.read { transaction in
            try transaction.fetchOne(query)
          }

          let observer = TransactionEventRecorder()
          let subscription = try reader.subscribe(transactionObserver: observer)
          try await writer.execute(sql: currentItemsViewRedefinition)

          let value = try await reader.read { transaction in
            try transaction.fetchOne(query)
          }
          #expect(value == "Alternate")
          #expect(
            observer.readRegions == [
              OrbitDatabaseRegion(column: "title", in: "current_items")
                .union(OrbitDatabaseRegion(column: "title", in: "alternate_items"))
            ]
          )
          _ = subscription
        }
      }

      @Test
      func attachingADatabasePublishesNoChangedRegion() async throws {
        let driver = try await itemsDatabase()
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let subscription = try driver.subscribe(transactionObserver: observer)

        try await driver.execute(sql: "ATTACH DATABASE ':memory:' AS archive")
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
        let driver = try await itemsDatabase()
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
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

      @Test
      func contextReportsTheLifecycleToDatabaseAndScopedObservers() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.executeBlocking(
          sql: """
            CREATE TABLE items (id INTEGER PRIMARY KEY);
            INSERT INTO items VALUES (1);
            """
        )
        let databaseObservers = OrbitDatabaseTransactionObservers()
        let databaseObserver = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let subscription = databaseObservers.subscribe(databaseObserver)
        let scopedObserver = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let scopedObservers = OrbitDatabaseTransactionObservers()
        let scopedSubscription = scopedObservers.subscribe(scopedObserver)
        let region = OrbitDatabaseRegion(table: "items")

        try driver.readBlocking { transaction in
          let context = SQLiteConnectionEvents()
          try context.withObservation(databaseObservers) {
            try context.withObservation(scopedObservers) {
              context.didChange(in: region)
              try context.willCommit(transaction)
              context.didCommit()
              context.didChange(in: region)
              context.didRollback()
            }
            context.didChange(in: region)
            context.didCommit()
          }
        }

        #expect(
          databaseObserver.events == [
            .didChange(region),
            .willCommit(1),
            .didCommit(.local),
            .didChange(region),
            .didRollback,
            .didChange(region),
            .didCommit(.local)
          ]
        )
        #expect(
          scopedObserver.events == [
            .didChange(region),
            .willCommit(1),
            .didCommit(.local),
            .didChange(region),
            .didRollback
          ]
        )
        _ = (subscription, scopedSubscription)
      }

      @Test
      func contextCommitsPendingChangesOnlyWhenThereAreSome() {
        let databaseObservers = OrbitDatabaseTransactionObservers()
        let databaseObserver = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let subscription = databaseObservers.subscribe(databaseObserver)
        let scopedObserver = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let scopedObservers = OrbitDatabaseTransactionObservers()
        let scopedSubscription = scopedObservers.subscribe(scopedObserver)
        let context = SQLiteConnectionEvents()
        let region = OrbitDatabaseRegion(table: "items")

        context.withObservation(databaseObservers) {
          context.withObservation(scopedObservers) {
            context.didCommitPendingChanges()
            context.didChange(in: .empty)
            context.didCommitPendingChanges()

            context.didChange(in: region)
            context.didChange(in: region)
            context.didCommitPendingChanges()
            context.didCommitPendingChanges()

            context.didChange(in: region)
            context.didRollback()
            context.didCommitPendingChanges()

            context.didChange(in: region)
            context.didCommit()
            context.didCommitPendingChanges()
          }
        }

        let expected: [TransactionEventRecorder.Event] = [
          .didChange(region),
          .didChange(region),
          .didCommit(.local),
          .didChange(region),
          .didRollback,
          .didChange(region),
          .didCommit(.local)
        ]
        #expect(databaseObserver.events == expected)
        #expect(scopedObserver.events == expected)
        _ = (subscription, scopedSubscription)
      }

      @Test
      func nativeObservationScopesNestAndStopAtTheirBoundaries() throws {
        let driver = try SQLiteQueue(path: .memory)
        let outer = TransactionEventRecorder()
        let inner = TransactionEventRecorder()
        let items = OrbitDatabaseRegion(table: "items")
        let lists = OrbitDatabaseRegion(table: "lists")

        try driver.readBlocking { transaction in
          transaction.notifyReads(in: lists)
          transaction.withObservation(outer) {
            transaction.notifyReads(in: items)
            transaction.withObservation(inner) {
              transaction.notifyReads(in: lists)
            }
            transaction.notifyReads(in: items)
          }
          transaction.notifyReads(in: lists)
        }

        #expect(outer.readRegions == [items, lists, items])
        #expect(inner.readRegions == [lists])
        #expect(outer.events.isEmpty && inner.events.isEmpty)
      }

      @Test
      func nativeConnectionObservationReportsCommittedChangesBeforeAThrowingScopeEnds() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.executeBlocking(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
        let observer = TransactionEventRecorder()

        #expect(throws: TestError()) {
          try driver.writeWithoutTransactionBlocking { connection in
            try connection.withObservation(observer) {
              try connection.execute("INSERT INTO items VALUES (1)")
              throw TestError()
            }
          }
        }

        let items = OrbitDatabaseRegion(table: "items")
        #expect(observer.events == [.didChange(items), .didCommit(.local)])
        #expect(observer.commits.map(\.region) == [items])
        let count = try driver.readBlocking { transaction in
          try transaction.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
        #expect(count == 1)
      }

      @Test
      func nativeConnectionObserverCanRejectAnExplicitCommit() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.executeBlocking(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
        let observer = TransactionEventRecorder(
          countOnWillCommit: itemCountSQL,
          commitError: TestError()
        )

        #expect(throws: TestError()) {
          try driver.writeWithoutTransactionBlocking { connection in
            try connection.withObservation(observer) {
              try connection.transaction { transaction in
                try transaction.execute("INSERT INTO items VALUES (1)")
              }
            }
          }
        }

        let items = OrbitDatabaseRegion(table: "items")
        #expect(observer.events == [.didChange(items), .willCommit(1), .didRollback])
        #expect(observer.commits.isEmpty)
        let count = try driver.readBlocking { transaction in
          try transaction.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
        #expect(count == 0)
      }

      @Test
      func observerScopedToAWriteBodyDoesNotSeeTheCommitThatFollowsIt() async throws {
        let driver = try await itemsDatabase()
        let observer = TransactionEventRecorder(countOnWillCommit: itemCountSQL)
        let subscription = try driver.subscribe(transactionObserver: observer)
        let scopedObserver = TransactionEventRecorder(countOnWillCommit: itemCountSQL)

        try await driver.write { transaction in
          _ = try transaction.withObservation(scopedObserver) {
            try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          }
        }

        let table = OrbitDatabaseRegion(table: "items")
        #expect(
          observer.events == [
            .didChange(table),
            .willCommit(1),
            .didCommit(.local)
          ]
        )
        #expect(scopedObserver.events == [.didChange(table)])
        _ = subscription
      }
    }

    enum LifecycleWrite: CaseIterable, Sendable {
      case queue, blocking, pool
    }

  #endif
#endif
