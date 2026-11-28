#if BuiltInSQLite
  import Foundation
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
            try connection.execute("INSERT INTO items (id) VALUES (1)")
            // Another connection sees the row already, so the statement committed as it finished.
            #expect(try peer.readBlocking { try $0.fetchOne(itemCount, as: Int.self) } == 1)
            try connection.executeScript(
              """
              INSERT INTO items (id) VALUES (2);
              INSERT INTO items (id) VALUES (1);
              """
            )
          }
        }

        #expect(error?.primaryCode == .constraint)
        #expect(try await driver.read { try $0.fetchAll(itemIDs, as: Int.self) } == [1, 2])
      }
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func transactionRollsBackOnThrowAndLeavesEarlierStatementsCommitted(
      _ kind: SQLiteTestDriver
    ) async throws {
      try await kind.withDatabase(schema: itemsSchema) { driver in
        try await driver.writeWithoutTransaction { connection in
          try connection.execute("INSERT INTO items (id) VALUES (1)")
          #expect(throws: TestError()) {
            try connection.transaction { transaction in
              try transaction.execute("INSERT INTO items (id) VALUES (2)")
              throw TestError()
            }
          }
          try connection.transaction { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (3)")
          }
        }

        #expect(try await driver.read { try $0.fetchAll(itemIDs, as: Int.self) } == [1, 3])
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
          try connection.execute("INSERT INTO items (id) VALUES (3)")
        }
        try await driver.readWithoutTransaction { connection in
          let error = #expect(throws: SQLiteError.self) {
            _ = try connection.rowCursor("BEGIN")
          }
          #expect(error?.primaryCode == .auth)
        }

        #expect(try await driver.read { try $0.fetchAll(itemIDs, as: Int.self) } == [2, 3])
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
          try connection.execute("INSERT INTO items (id) VALUES (1)")
        }

        // The connection was handed back with no transaction open, so the next write can begin
        // one.
        try await driver.write { transaction in
          try transaction.execute("INSERT INTO items (id) VALUES (2)")
        }
        #expect(try await driver.read { try $0.fetchAll(itemIDs, as: Int.self) } == [2])
      }
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func observersSeeStatementsOutsideATransactionAsCommits(
      _ kind: SQLiteTestDriver
    ) async throws {
      try await kind.withDatabase(schema: itemsSchema) { driver in
        let observer = TransactionEventRecorder(countOnWillCommit: itemCount)
        let subscription = try driver.subscribe(transactionObserver: observer)
        let items = OrbitDatabaseRegion(table: "items")
        let manual = OrbitDatabaseRegion(table: "manual")

        try await driver.writeWithoutTransaction { connection in
          _ = try connection.fetchAll(itemIDs, as: Int.self)
          try connection.execute("PRAGMA foreign_keys = ON")
          try connection.execute("INSERT INTO items (id) VALUES (1)")
          // A statement that fails after reporting its change still reports it as committed.
          try? connection.execute("INSERT INTO items (id) VALUES (1)")
          connection.notifyChanges(in: manual)
          try connection.transaction { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (2)")
          }
          try? connection.transaction { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (3)")
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
        try await driver.execute(
          sql: """
            CREATE TABLE lists (id INTEGER PRIMARY KEY);
            CREATE TABLE entries (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists (id));
            """
        )
        let orphan: SQL = "INSERT INTO entries (id, listID) VALUES (1, 1)"
        let foreignKeys: SQL = "PRAGMA foreign_keys"

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
          return try connection.fetchOne(foreignKeys, as: Int.self)
        }

        #expect(enforcedDuringAccess == 0)
        #expect(
          try await driver.writeWithoutTransaction { try $0.fetchOne(foreignKeys, as: Int.self) }
            == 1
        )
        #expect(try await driver.rowCount(of: "entries") == 1)
      }
    }

    // That reads refuse SQL that may write is RawSQLDatabaseTests'; this is what is left behind.
    @Test(arguments: SQLiteTestDriver.allCases)
    func readConnectionRefusesWritesAndLeavesTheConnectionWritable(
      _ kind: SQLiteTestDriver
    ) async throws {
      try await kind.withDatabase(schema: itemsSchema) { driver in
        let error = await #expect(throws: SQLiteError.self) {
          try await driver.readWithoutTransaction { connection in
            try connection.fetchAll("INSERT INTO items (id) VALUES (1) RETURNING id", as: Int.self)
          }
        }
        #expect(error?.primaryCode == .readOnly)

        // A pool's readers are query-only besides.
        if kind == .pool {
          let queryOnly = try await driver.read { transaction in
            try transaction.fetchOne("PRAGMA query_only", as: Bool.self)
          }
          #expect(queryOnly == true)
        }

        try await driver.writeWithoutTransaction { connection in
          try connection.execute("INSERT INTO items (id) VALUES (2)")
        }
        let ids = try await driver.readWithoutTransaction { connection in
          try connection.transaction { try $0.fetchAll(itemIDs, as: Int.self) }
        }
        #expect(ids == [2])
      }
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func writeConnectionRefusesMutationCursors(_ kind: SQLiteTestDriver) async throws {
      try await kind.withDatabase(schema: itemsSchema) { driver in
        try await driver.writeWithoutTransaction { connection in
          for cached in [false, true] {
            let error = #expect(throws: SQLiteError.self) {
              _ = try connection.rowCursor(
                "INSERT INTO items (id) VALUES (1) RETURNING id",
                cached: cached
              )
            }
            #expect(error?.primaryCode == .readOnly)
          }

          #expect(try connection.fetchAll(itemIDs, as: Int.self).isEmpty)
          try connection.execute("INSERT INTO items (id) VALUES (2)")
          #expect(try connection.fetchAll(itemIDs, as: Int.self) == [2])
        }
        #expect(try await driver.read { try $0.fetchAll(itemIDs, as: Int.self) } == [2])
      }
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func cachedMutationCursorsStayAvailableOnlyInsideExplicitTransactions(
      _ kind: SQLiteTestDriver
    ) async throws {
      try await kind.withDatabase(schema: itemsSchema) { driver in
        try await driver.writeWithoutTransaction { connection in
          let insert: SQL = "INSERT INTO items (id) VALUES (\(1)) RETURNING id"
          let inserted = try connection.transaction { transaction in
            var cursor = try transaction.executeRowCursor(insert, cached: true)
            return try cursor.collect { $0[0].integerValue }
          }
          #expect(inserted == [1])

          // This SQL now has a writable statement in the same connection's cache. The read-only
          // restriction must be checked when borrowing it as well as when preparing a new one.
          let error = #expect(throws: SQLiteError.self) {
            _ = try connection.rowCursor(insert, cached: true)
          }
          #expect(error?.primaryCode == .readOnly)

          // In a write transaction the statement may write again, borrowing the cached writable
          // statement.
          let insertedAgain = try connection.transaction { transaction in
            var cursor = try transaction.executeRowCursor(
              "INSERT INTO items (id) VALUES (\(2)) RETURNING id",
              cached: true
            )
            return try cursor.collect { $0[0].integerValue }
          }
          #expect(insertedAgain == [2])
        }
        #expect(try await driver.read { try $0.fetchAll(itemIDs, as: Int.self) } == [1, 2])
      }
    }

    @Test(arguments: SQLiteTestDriver.allCases)
    func blockingAccessesWithoutTransactionReadAndWrite(_ kind: SQLiteTestDriver) throws {
      try withTestDatabaseFile { file in
        let driver = try file.open(kind)

        try driver.writeWithoutTransactionBlocking { connection in
          try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
          try connection.execute("INSERT INTO items (id) VALUES (1)")
          try connection.transaction { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (2)")
          }
        }
        let ids = try driver.readWithoutTransactionBlocking { connection in
          try connection.fetchAll(itemIDs, as: Int.self)
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
          return try connection.fetchAll(
            """
            WITH RECURSIVE counter(x) AS (
              SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 2000000000
            )
            SELECT count(*) FROM counter
            """,
            as: Int.self
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
        try connection.fetchOne(itemCount, as: Int.self)
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
          try connection.execute("INSERT INTO items (id) VALUES (1), (2), (3)")
          let inserted = connection.changesCount
          let rowID = connection.lastInsertedRowID
          try connection.execute("DELETE FROM items WHERE id = 2")
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
  private let itemIDs: SQL = "SELECT id FROM items ORDER BY id"
  private let itemCount: SQL = "SELECT count(*) FROM items"
#endif
