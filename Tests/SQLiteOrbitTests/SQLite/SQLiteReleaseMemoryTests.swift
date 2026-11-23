#if BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  #if SystemSQLite
    import CSQLite3
  #endif

  // Releasing memory finalizes the statements a connection keeps idle and asks SQLite to free its
  // unused cache pages. These hold it to freeing that, to leaving the statements in use alone, and
  // to leaving the connection as usable as it was.
  @Suite
  struct SQLiteReleaseMemoryTests {
    private static let queries: [SQL] = [
      "SELECT count(*) FROM items",
      "SELECT max(value) FROM items",
      "SELECT min(value) FROM items",
      "SELECT sum(value) FROM items",
    ]

    private static func makeItems(_ owner: inout SQLiteConnection, count: Int = 10) throws {
      try owner.write { transaction in
        try transaction.execute("CREATE TABLE items (value INTEGER NOT NULL)")
        for value in 1...count {
          try transaction.execute("INSERT INTO items (value) VALUES (\(value))")
        }
      }
    }

    private static func runQueries(
      _ transaction: borrowing SQLiteReadTransaction
    ) throws -> [Int64?] {
      var results: [Int64?] = []
      for query in queries {
        let value: Int64?? = try transaction.fetchOne(query) { row in row[0].integerValue }
        results.append(value ?? nil)
      }
      return results
    }

    @Test
    func releasingMemoryFinalizesIdleStatementsAndTheConnectionCachesAgain() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try Self.makeItems(&owner)
      let results = try owner.read { try Self.runQueries($0) }
      #expect(results == [10, 10, 1, 55])
      #expect(owner.statements.idleStatementCount >= Self.queries.count)

      owner.releaseMemory()
      #expect(owner.statements.idleStatementCount == 0)

      // The connection still works, and caches the statements it compiles again.
      #expect(try owner.read { try Self.runQueries($0) } == results)
      #expect(owner.statements.idleStatementCount >= Self.queries.count)
      try owner.write { try $0.execute("INSERT INTO items (value) VALUES (11)") }
      #expect(try owner.read { try Self.runQueries($0) } == [11, 11, 1, 66])
    }

    @Test
    func borrowedConnectionsReleaseInsideAndOutsideTransactions() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try Self.makeItems(&owner)

      let (inside, outside) = try owner.withReadConnection { connection in
        let statements = connection.handle.pointee.statements
        let inside = try connection.transaction { transaction in
          _ = try Self.runQueries(transaction)
          connection.releaseMemory()
          let count = statements.idleStatementCount
          // The read transaction is still open and usable.
          return (count, try Self.runQueries(transaction))
        }
        _ = try connection.fetchAll("SELECT value FROM items") { $0[0].integerValue }
        connection.releaseMemory()
        return (inside, statements.idleStatementCount)
      }
      #expect(inside.0 == 0)
      #expect(inside.1 == [10, 10, 1, 55])
      #expect(outside == 0)

      let count = try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          try transaction.execute("INSERT INTO items (value) VALUES (11)")
          connection.releaseMemory()
          try transaction.execute("INSERT INTO items (value) VALUES (12)")
        }
        try connection.execute("INSERT INTO items (value) VALUES (13)")
        connection.releaseMemory()
        return try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
      }
      #expect(count == 13)
    }

    @Test
    func anOpenCursorKeepsIteratingAcrossARelease() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try Self.makeItems(&owner, count: 20)
      let sql: SQL = "SELECT value FROM items ORDER BY value"

      let values = try owner.withReadConnection { connection in
        // Something else idle in the cache, so the release has something to finalize.
        _ = try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        var cursor = try connection.rowCursor(sql)
        var values: [Int64] = []
        while values.count < 5, let row = try cursor.next() {
          values.append(row[0].integerValue ?? -1)
        }
        connection.releaseMemory()
        #expect(connection.handle.pointee.statements.idleStatementCount == 0)
        while let row = try cursor.next() {
          values.append(row[0].integerValue ?? -1)
        }
        return values
      }
      #expect(values == Array(1...20))
      // The cursor's statement was still valid, so it went back to the cache when the cursor ended.
      #expect(owner.statements.idleStatementCount == 1)
    }

    @Test
    func aLentPreparedStatementKeepsRunningAcrossARelease() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try Self.makeItems(&owner, count: 1)
      let values = try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          var insert = try transaction.prepare("INSERT INTO items (value) VALUES (?)")
          var select = try transaction.prepare("SELECT value FROM items ORDER BY value")
          try insert.execute(2)
          _ = try select.fetchAll { $0[0].integerValue }
          connection.releaseMemory()
          try insert.execute(3)
          return try select.fetchAll { $0[0].integerValue }
        }
      }
      #expect(values == [1, 2, 3])
    }

    #if SystemSQLite
      @Test
      func theSystemLibraryReleasesMemoryThroughSQLite() {
        #expect(SQLiteLibrary.system.connections.releaseMemory != nil)
      }

      @Test
      func releasingMemoryShrinksThePageCache() throws {
        try withTestDatabaseFile("release-memory") { file in
          var owner = try SQLiteConnection(path: file.path, configuration: .default)
          try owner.write { transaction in
            try transaction.execute("CREATE TABLE blobs (payload BLOB NOT NULL)")
            try transaction.execute(
              """
              WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
              INSERT INTO blobs (payload) SELECT randomblob(1000) FROM n
              """
            )
          }
          let total = try owner.read { transaction in
            try transaction.fetchOne("SELECT sum(length(payload)) FROM blobs") {
              $0[0].integerValue
            }
          }
          #expect(total == 2_000_000)

          func cacheUsed() -> Int32 {
            var current: Int32 = 0
            var highwater: Int32 = 0
            let code = sqlite3_db_status(
              owner.pointer,
              SQLITE_DBSTATUS_CACHE_USED,
              &current,
              &highwater,
              0
            )
            #expect(code == SQLITE_OK)
            return current
          }
          let before = cacheUsed()
          #expect(before > 1_000_000)
          owner.releaseMemory()
          let after = cacheUsed()
          #expect(after < before / 4)

          // The pages are read again when they are needed.
          let again = try owner.read { transaction in
            try transaction.fetchOne("SELECT sum(length(payload)) FROM blobs") {
              $0[0].integerValue
            }
          }
          #expect(again == total)
        }
      }
    #endif

    #if Turso
      @Test
      func tursoHasNoReleaseMemoryEntryPoint() throws {
        #expect(SQLiteLibrary.turso.connections.releaseMemory == nil)
      }
    #endif

    @Test
    func aLibraryWithoutTheEntryPointStillFinalizesIdleStatements() throws {
      var configuration = SQLiteConfiguration.default
      configuration.library.connections.releaseMemory = nil
      var owner = try SQLiteConnection(path: ":memory:", configuration: configuration)
      try Self.makeItems(&owner)
      _ = try owner.read { try Self.runQueries($0) }
      #expect(owner.statements.idleStatementCount > 0)
      owner.releaseMemory()
      #expect(owner.statements.idleStatementCount == 0)
      #expect(try owner.read { try Self.runQueries($0) } == [10, 10, 1, 55])
    }

    // MARK: - Drivers

    @Test
    func aQueueReleasesItsConnectionsIdleStatements() async throws {
      let queue = try SQLiteQueue(path: .memory)
      try await queue.write { transaction in
        try transaction.execute("CREATE TABLE items (value INTEGER NOT NULL)")
        try transaction.execute("INSERT INTO items (value) VALUES (1), (2), (3)")
      }
      let idleCount: @Sendable (borrowing SQLiteReadConnection) -> Int = {
        $0.handle.pointee.statements.idleStatementCount
      }
      let sum = try await queue.read { transaction in
        _ = try Self.runQueries(transaction)
        return try transaction.fetchOne("SELECT sum(value) FROM items") { $0[0].integerValue }
      }
      #expect(sum == 6)
      #expect(try await queue.readWithoutTransaction(idleCount) > 0)

      let memoryReleasing: any OrbitMemoryReleasing = queue
      await memoryReleasing.releaseMemory()
      #expect(try await queue.readWithoutTransaction(idleCount) == 0)
      #expect(try await queue.read { try Self.runQueries($0) } == [3, 3, 1, 6])
    }

    @Test
    func aQueueReleasesFromACancelledTask() async throws {
      let queue = try SQLiteQueue(path: .memory)
      _ = try await queue.read { try $0.fetchOne("SELECT 1") { $0[0].integerValue } }
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await queue.releaseMemory()
      }
      await task.value
      let idle = try await queue.readWithoutTransaction {
        $0.handle.pointee.statements.idleStatementCount
      }
      #expect(idle == 0)
    }

    @Test
    func aSuspendedSerialConnectionStillReleases() async throws {
      try await withTestDatabaseFile("release-suspended") { file in
        let suspension = SQLiteWriteSuspension(path: file.path)
        let connection = try SQLiteSerialConnection(
          path: file.path,
          configuration: .default,
          suspension: suspension
        )
        try await connection.withWriteConnection { connection in
          try connection.execute("CREATE TABLE items (value INTEGER NOT NULL)")
          try connection.execute("INSERT INTO items (value) VALUES (1)")
        }
        let count = try await connection.withReadConnection { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
        #expect(count == 1)

        suspension.suspend()
        await connection.releaseMemory()
        let (idle, countAfter) = try await connection.withReadConnection { connection in
          (
            connection.handle.pointee.statements.idleStatementCount,
            try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
          )
        }
        #expect(idle == 0)
        #expect(countAfter == 1)
        // The release left the suspension as it was.
        await #expect(throws: OrbitDatabaseSuspendedError.self) {
          try await connection.withWriteConnection { connection in
            try connection.execute("INSERT INTO items (value) VALUES (2)")
          }
        }
        suspension.resume()
        try await connection.withWriteConnection { connection in
          try connection.execute("INSERT INTO items (value) VALUES (2)")
        }
      }
    }
  }
#endif
