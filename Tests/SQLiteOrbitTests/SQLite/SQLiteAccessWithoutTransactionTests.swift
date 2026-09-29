#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Foundation
    import StructuredQueriesSQLite
    import Testing

    @testable import SQLiteOrbit

    @Suite
    struct SQLiteAccessWithoutTransactionTests {
      @Test(arguments: SQLiteTestDriver.allCases)
      func statementsOutsideATransactionCommitOneByOne(_ kind: SQLiteTestDriver) async throws {
        try await withTestDatabaseFile { file in
          let driver = try file.open(kind)
          try await driver.execute(sql: itemsSchema)
          let peer = try file.queue()

          let error = await #expect(throws: SQLiteError.self) {
            try await driver.writeWithoutTransaction { connection in
              try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
              // Another connection sees the row already, so the statement committed as it finished.
              #expect(try peer.readBlocking { try $0.fetchOne(itemCount) } == 1)
              try connection.executeScript(
                """
                INSERT INTO items (id) VALUES (2);
                INSERT INTO items (id) VALUES (1);
                """
              )
            }
          }

          #expect(error?.primaryCode == .constraint)
          #expect(try await driver.read { try $0.fetchAll(itemIDs) } == [1, 2])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func transactionRollsBackOnThrowAndLeavesEarlierStatementsCommitted(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          try await driver.writeWithoutTransaction { connection in
            try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
            #expect(throws: TestError()) {
              try connection.transaction { transaction in
                try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
                throw TestError()
              }
            }
            try connection.transaction { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (3)", as: Void.self))
            }
          }

          #expect(try await driver.read { try $0.fetchAll(itemIDs) } == [1, 3])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func transactionControlIsRefusedOutsideTheConnectionsTransaction(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          let statements = [
            "BEGIN", "BEGIN IMMEDIATE", "COMMIT", "ROLLBACK", "SAVEPOINT outer", "RELEASE outer"
          ]

          try await driver.writeWithoutTransaction { connection in
            for sql in statements {
              let error = #expect(throws: SQLiteError.self) { try connection.executeScript(sql) }
              #expect(error?.primaryCode == .auth)
            }
            // Savepoints nest inside the connection's own transaction as they do in any other.
            try connection.transaction { transaction in
              try transaction.executeScript(
                """
                SAVEPOINT inner;
                INSERT INTO items (id) VALUES (1);
                ROLLBACK TO inner;
                RELEASE inner;
                INSERT INTO items (id) VALUES (2);
                """
              )
            }
            try connection.execute(#sql("INSERT INTO items (id) VALUES (3)", as: Void.self))
          }
          try await driver.readWithoutTransaction { connection in
            let error = #expect(throws: SQLiteError.self) {
              _ = try connection.rowCursor(#sql("BEGIN", as: Void.self))
            }
            #expect(error?.primaryCode == .auth)
          }

          #expect(try await driver.read { try $0.fetchAll(itemIDs) } == [2, 3])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func transactionLeftOpenWhenTheAccessEndsIsRolledBack(_ kind: SQLiteTestDriver) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          let savepoint = #sql("SAVEPOINT leftover", as: Void.self)

          try await driver.writeWithoutTransaction { connection in
            // A statement the cache prepared inside the transaction is never shown to the authorizer
            // again, so reusing it outside is the one way left to open a transaction there.
            try connection.transaction { transaction in
              var cursor = try transaction.rowCursor(savepoint, cached: true)
              while try cursor.next() != nil {}
            }
            var cursor = try connection.rowCursor(savepoint, cached: true)
            while try cursor.next() != nil {}
            try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          }

          // The connection was handed back with no transaction open, so the next write can begin one.
          try await driver.write { transaction in
            try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
          }
          #expect(try await driver.read { try $0.fetchAll(itemIDs) } == [2])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func observersSeeStatementsOutsideATransactionAsCommits(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          let observer = TransactionEventRecorder(countOnWillCommit: SQL(fragment: itemCount.query))
          let subscription = try driver.subscribe(transactionObserver: observer)
          let items = OrbitDatabaseRegion(table: "items")
          let manual = OrbitDatabaseRegion(table: "manual")

          try await driver.writeWithoutTransaction { connection in
            _ = try connection.fetchAll(itemIDs)
            try connection.execute("PRAGMA foreign_keys = ON")
            try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
            // A statement that fails after reporting its change still reports it as committed.
            try? connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
            connection.notifyChanges(in: manual)
            try connection.transaction { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
            }
            try? connection.transaction { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (3)", as: Void.self))
              throw TestError()
            }
          }

          #expect(
            observer.events == [
              .didChange(items),
              .didCommit(.local),
              .didChange(items),
              .didCommit(.local),
              .didChange(manual),
              .didCommit(.local),
              .didChange(items),
              .willCommit(2),
              .didCommit(.local),
              .didChange(items),
              .didRollback
            ]
          )
          _ = subscription
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func foreignKeysPragmaTakesEffectOnlyOutsideATransaction(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          try await driver.write { transaction in
            try transaction.executeScript(
              """
              CREATE TABLE lists (id INTEGER PRIMARY KEY);
              CREATE TABLE entries (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists (id));
              """
            )
          }
          let orphan = #sql("INSERT INTO entries (id, listID) VALUES (1, 1)", as: Void.self)
          let foreignKeys = #sql("PRAGMA foreign_keys", as: Int.self)

          // Inside a transaction SQLite ignores the pragma, so the orphan is still refused.
          await #expect(throws: SQLiteError.self) {
            try await driver.write { transaction in
              try transaction.execute("PRAGMA foreign_keys = OFF")
              try transaction.execute(orphan)
            }
          }

          let enforcedDuringAccess = try await driver.writeWithoutTransaction { connection in
            try connection.execute("PRAGMA foreign_keys = OFF")
            defer { try? connection.execute("PRAGMA foreign_keys = ON") }
            try connection.transaction { transaction in
              try transaction.execute(orphan)
            }
            return try connection.fetchOne(foreignKeys)
          }

          #expect(enforcedDuringAccess == 0)
          #expect(try await driver.writeWithoutTransaction { try $0.fetchOne(foreignKeys) } == 1)
          let orphans = try await driver.read { transaction in
            try transaction.fetchOne(#sql("SELECT count(*) FROM entries", as: Int.self))
          }
          #expect(orphans == 1)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func readConnectionRefusesWritesAndLeavesTheConnectionWritable(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          let error = await #expect(throws: SQLiteError.self) {
            try await driver.readWithoutTransaction { connection in
              try connection.fetchAll(
                #sql("INSERT INTO items (id) VALUES (1) RETURNING id", as: Int.self)
              )
            }
          }
          #expect(error?.primaryCode == .readOnly)

          try await driver.writeWithoutTransaction { connection in
            try connection.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
          }
          let ids = try await driver.readWithoutTransaction { connection in
            try connection.transaction { try $0.fetchAll(itemIDs) }
          }
          #expect(ids == [2])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func blockingAccessesWithoutTransactionReadAndWrite(_ kind: SQLiteTestDriver) throws {
        try withTestDatabaseFile { file in
          let driver = try file.open(kind)

          try driver.writeWithoutTransactionBlocking { connection in
            try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
            try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
            try connection.transaction { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
            }
          }
          let ids = try driver.readWithoutTransactionBlocking { connection in
            try connection.fetchAll(itemIDs)
          }

          #expect(ids == [1, 2])
        }
      }

      @Test
      func cancellingAnAccessWithoutTransactionInterruptsItsStatement() async throws {
        let steps = TestCounter()
        let base = builtInTestLibrary
        var configuration = SQLiteConfiguration.default
        configuration.library = base
        configuration.library.statements.execution.step = { statement in
          if let sql = base.statements.inspection.sql(statement),
            String(cString: sql).contains("RECURSIVE counter")
          {
            steps.increment()
          }
          return base.statements.execution.step(statement)
        }
        let driver = try SQLiteQueue(path: .memory, configuration: configuration)

        let running = Task {
          try await driver.writeWithoutTransaction { connection in
            try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
            return try connection.fetchAll(
              #sql(
                """
                WITH RECURSIVE counter(x) AS (
                  SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 2000000000
                )
                SELECT count(*) FROM counter
                """,
                as: Int.self
              )
            )
          }
        }
        try await steps.waitForCount(1)
        running.cancel()

        await #expect(throws: CancellationError.self) {
          _ = try await running.value
        }
        // The table created before the interrupted statement stays committed.
        let count = try await driver.readWithoutTransaction { connection in
          try connection.fetchOne(itemCount)
        }
        #expect(count == 0)
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func aConnectionReportsWhatEachStatementChangedAndInserted(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          let report = try await driver.writeWithoutTransaction {
            connection -> (inserted: Int, rowID: Int64, deleted: Int) in
            try connection.execute(
              #sql("INSERT INTO items (id) VALUES (1), (2), (3)", as: Void.self)
            )
            let inserted = connection.changesCount
            let rowID = connection.lastInsertedRowID
            try connection.execute(#sql("DELETE FROM items WHERE id = 2", as: Void.self))
            return (inserted, rowID, connection.changesCount)
          }

          #expect(report.inserted == 3)
          #expect(report.rowID == 3)
          // Only the delete is counted, not the insert before it.
          #expect(report.deleted == 1)
        }
      }
    }

    private let itemsSchema = "CREATE TABLE items (id INTEGER PRIMARY KEY)"
    private let itemIDs = #sql("SELECT id FROM items ORDER BY id", as: Int.self)
    private let itemCount = #sql("SELECT count(*) FROM items", as: Int.self)
  #endif
#endif
