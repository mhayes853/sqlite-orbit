#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Foundation
    import StructuredQueriesSQLite
    import Testing

    @testable import SQLiteOrbit

    @Suite(.libraryHooks)
    struct SQLiteAccessWithoutTransactionTests {
      @Test(arguments: SQLiteTestDriver.allCases)
      func statementsOutsideATransactionCommitOneByOne(_ kind: SQLiteTestDriver) async throws {
        try await withTestDatabaseFile { file in
          let driver = try file.open(kind)
          try await driver.execute(sql: itemsSchema)
          let peer = try file.queue()

          let error = await #expect(throws: SQLiteError.self) {
            try await driver.writeWithoutTransaction { connection in
              try #sql("INSERT INTO items (id) VALUES (1)", as: Void.self).execute(connection)
              // Another connection sees the row already, so the statement committed as it finished.
              #expect(try peer.readBlocking { try itemCount.fetchOne($0) } == 1)
              try connection.executeScript(
                """
                INSERT INTO items (id) VALUES (2);
                INSERT INTO items (id) VALUES (1);
                """
              )
            }
          }

          #expect(error?.primaryCode == .constraint)
          #expect(try await driver.read { try itemIDs.fetchAll($0) } == [1, 2])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func transactionRollsBackOnThrowAndLeavesEarlierStatementsCommitted(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          try await driver.writeWithoutTransaction { connection in
            try #sql("INSERT INTO items (id) VALUES (1)", as: Void.self).execute(connection)
            #expect(throws: TestError()) {
              try connection.transaction { transaction in
                try #sql("INSERT INTO items (id) VALUES (2)", as: Void.self).execute(transaction)
                throw TestError()
              }
            }
            try connection.transaction { transaction in
              try #sql("INSERT INTO items (id) VALUES (3)", as: Void.self).execute(transaction)
            }
          }

          #expect(try await driver.read { try itemIDs.fetchAll($0) } == [1, 3])
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
            try #sql("INSERT INTO items (id) VALUES (3)", as: Void.self).execute(connection)
          }
          try await driver.readWithoutTransaction { connection in
            let error = #expect(throws: SQLiteError.self) {
              _ = try connection.rowCursor(SQL(fragment: #sql("BEGIN", as: Void.self).query))
            }
            #expect(error?.primaryCode == .auth)
          }

          #expect(try await driver.read { try itemIDs.fetchAll($0) } == [2, 3])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func transactionLeftOpenWhenTheAccessEndsIsRolledBack(_ kind: SQLiteTestDriver) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          try await driver.writeWithoutTransaction { connection in
            // Native statement execution bypasses the cursor's transaction-scope check.
            let statement = try connection.transaction { transaction in
              try #require(
                try transaction.sqlite.prepare(
                  "SAVEPOINT leftover",
                  on: transaction.sqliteConnection
                )
              )
            }
            defer { _ = connection.sqlite.statements.execution.finalize(statement) }
            #expect(
              connection.sqlite.statements.execution.step(statement)
                == SQLiteResultCode.done.rawValue
            )
            #expect(connection.sqlite.connections.isAutocommit(connection.sqliteConnection) == 0)
            try #sql("INSERT INTO items (id) VALUES (1)", as: Void.self).execute(connection)
          }

          // The connection was handed back with no transaction open, so the next write can begin one.
          try await driver.write { transaction in
            try #sql("INSERT INTO items (id) VALUES (2)", as: Void.self).execute(transaction)
          }
          #expect(try await driver.read { try itemIDs.fetchAll($0) } == [2])
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
            _ = try itemIDs.fetchAll(connection)
            try connection.execute("PRAGMA foreign_keys = ON")
            try #sql("INSERT INTO items (id) VALUES (1)", as: Void.self).execute(connection)
            // A statement that fails after reporting its change still reports it as committed.
            try? #sql("INSERT INTO items (id) VALUES (1)", as: Void.self).execute(connection)
            connection.notifyChanges(in: manual)
            try connection.transaction { transaction in
              try #sql("INSERT INTO items (id) VALUES (2)", as: Void.self).execute(transaction)
            }
            try? connection.transaction { transaction in
              try #sql("INSERT INTO items (id) VALUES (3)", as: Void.self).execute(transaction)
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
              try orphan.execute(transaction)
            }
          }

          let enforcedDuringAccess = try await driver.writeWithoutTransaction { connection in
            try connection.execute("PRAGMA foreign_keys = OFF")
            defer { try? connection.execute("PRAGMA foreign_keys = ON") }
            try connection.transaction { transaction in
              try orphan.execute(transaction)
            }
            return try foreignKeys.fetchOne(connection)
          }

          #expect(enforcedDuringAccess == 0)
          #expect(try await driver.writeWithoutTransaction { try foreignKeys.fetchOne($0) } == 1)
          let orphans = try await driver.read { transaction in
            try #sql("SELECT count(*) FROM entries", as: Int.self).fetchOne(transaction)
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
              try #sql("INSERT INTO items (id) VALUES (1) RETURNING id", as: Int.self)
                .fetchAll(connection)
            }
          }
          #expect(error?.primaryCode == .readOnly)

          try await driver.writeWithoutTransaction { connection in
            try #sql("INSERT INTO items (id) VALUES (2)", as: Void.self).execute(connection)
          }
          let ids = try await driver.readWithoutTransaction { connection in
            try connection.transaction { try itemIDs.fetchAll($0) }
          }
          #expect(ids == [2])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func writeConnectionRefusesRawAndTypedMutationCursors(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          try await driver.writeWithoutTransaction { connection in
            for cached in [false, true] {
              let rawError = #expect(throws: SQLiteError.self) {
                _ = try connection.rowCursor(
                  "INSERT INTO items (id) VALUES (1) RETURNING id",
                  cached: cached
                )
              }
              #expect(rawError?.primaryCode == .readOnly)

              let typedError = #expect(throws: SQLiteError.self) {
                _ = try connection.rowCursor(
                  SQL(
                    fragment: #sql("INSERT INTO items (id) VALUES (1) RETURNING id", as: Int.self)
                      .query
                  ),
                  cached: cached
                )
              }
              #expect(typedError?.primaryCode == .readOnly)
            }

            #expect(try itemIDs.fetchAll(connection).isEmpty)
            try connection.execute("INSERT INTO items (id) VALUES (2)")
            #expect(try itemIDs.fetchAll(connection) == [2])
          }
          #expect(try await driver.read { try itemIDs.fetchAll($0) } == [2])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func cachedMutationCursorsStayAvailableOnlyInsideExplicitTransactions(
        _ kind: SQLiteTestDriver
      ) async throws {
        try await kind.withDatabase(schema: itemsSchema) { driver in
          try await driver.writeWithoutTransaction { connection in
            let inserted = try connection.transaction { transaction in
              var cursor = try transaction.executeRowCursor(
                "INSERT INTO items (id) VALUES (1) RETURNING id",
                cached: true
              )
              return try cursor.collect { $0[0].integerValue }
            }
            #expect(inserted == [1])

            // This SQL now has a writable statement in the same connection's cache. The read-only
            // restriction must be checked when borrowing it as well as when preparing a new one.
            let rawError = #expect(throws: SQLiteError.self) {
              _ = try connection.rowCursor(
                "INSERT INTO items (id) VALUES (1) RETURNING id",
                cached: true
              )
            }
            #expect(rawError?.primaryCode == .readOnly)

            let typedError = #expect(throws: SQLiteError.self) {
              _ = try connection.rowCursor(
                SQL(
                  fragment: #sql("INSERT INTO items (id) VALUES (1) RETURNING id", as: Int.self)
                    .query
                ),
                cached: true
              )
            }
            #expect(typedError?.primaryCode == .readOnly)

            // A raw statement may write in a write transaction, where it borrows the cached
            // writable statement.
            let typedInserted = try connection.transaction { transaction in
              try #sql("INSERT INTO items (id) VALUES (2) RETURNING id", as: Int.self)
                .fetchAll(transaction)
            }
            #expect(typedInserted == [2])
          }
          #expect(try await driver.read { try itemIDs.fetchAll($0) } == [1, 2])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func blockingAccessesWithoutTransactionReadAndWrite(_ kind: SQLiteTestDriver) throws {
        try withTestDatabaseFile { file in
          let driver = try file.open(kind)

          try driver.writeWithoutTransactionBlocking { connection in
            try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
            try #sql("INSERT INTO items (id) VALUES (1)", as: Void.self).execute(connection)
            try connection.transaction { transaction in
              try #sql("INSERT INTO items (id) VALUES (2)", as: Void.self).execute(transaction)
            }
          }
          let ids = try driver.readWithoutTransactionBlocking { connection in
            try itemIDs.fetchAll(connection)
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
        configuration.library.statements.execution.step = LibraryHooks.step { statement in
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
            return try #sql(
              """
              WITH RECURSIVE counter(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 2000000000
              )
              SELECT count(*) FROM counter
              """,
              as: Int.self
            )
            .fetchAll(connection)
          }
        }
        try await steps.waitForCount(1)
        running.cancel()

        await #expect(throws: CancellationError.self) {
          _ = try await running.value
        }
        // The table created before the interrupted statement stays committed.
        let count = try await driver.readWithoutTransaction { connection in
          try itemCount.fetchOne(connection)
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
            try #sql("INSERT INTO items (id) VALUES (1), (2), (3)", as: Void.self)
              .execute(connection)
            let inserted = connection.changesCount
            let rowID = connection.lastInsertedRowID
            try #sql("DELETE FROM items WHERE id = 2", as: Void.self).execute(connection)
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
