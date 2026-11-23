#if BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  #if SystemSQLite
    import CSQLite3
  #endif

  // Releasing memory finalizes the statements a connection keeps idle and asks SQLite to free its
  // unused cache pages, leaving statements in use and the connection itself working.
  @Suite
  struct SQLiteReleaseMemoryTests {
    private static let queries: [SQL] = [
      "SELECT count(*) FROM items",
      "SELECT max(value) FROM items",
      "SELECT min(value) FROM items",
      "SELECT sum(value) FROM items"
    ]

    private static func makeOwner(
      count: Int = 10,
      configuration: SQLiteConfiguration = .default
    ) throws -> SQLiteConnection {
      var owner = try SQLiteConnection(path: ":memory:", configuration: configuration)
      try owner.write { transaction in
        try transaction.execute("CREATE TABLE items (value INTEGER NOT NULL)")
        for value in 1...count {
          try transaction.execute("INSERT INTO items (value) VALUES (\(value))")
        }
      }
      return owner
    }

    private static func runQueries(
      _ transaction: borrowing SQLiteReadTransaction
    ) throws -> [Int64?] {
      try queries.map { query in
        try transaction.fetchOne(query) { row in row[0].integerValue } ?? nil
      }
    }

    @Sendable
    private static func idleCount(_ connection: borrowing SQLiteReadConnection) -> Int {
      connection.handle.pointee.statements.idleStatementCount
    }

    // Without the library entry point, a release still finalizes the idle statements.
    @Test(arguments: [true, false])
    func releasingMemoryFinalizesIdleStatementsAndTheConnectionCachesAgain(
      hasEntryPoint: Bool
    ) throws {
      var configuration = SQLiteConfiguration.default
      if !hasEntryPoint { configuration.library.connections.releaseMemory = nil }
      var owner = try Self.makeOwner(configuration: configuration)
      let results = try owner.read { try Self.runQueries($0) }
      #expect(results == [10, 10, 1, 55])
      #expect(owner.statements.idleStatementCount >= Self.queries.count)

      owner.releaseMemory()
      #expect(owner.statements.idleStatementCount == 0)

      #expect(try owner.read { try Self.runQueries($0) } == results)
      #expect(owner.statements.idleStatementCount >= Self.queries.count)
      try owner.write { try $0.execute("INSERT INTO items (value) VALUES (11)") }
      #expect(try owner.read { try Self.runQueries($0) } == [11, 11, 1, 66])
    }

    @Test
    func borrowedConnectionsReleaseInsideAndOutsideTransactions() throws {
      var owner = try Self.makeOwner()

      let (inside, outside) = try owner.withReadConnection { connection in
        let inside = try connection.transaction { transaction in
          _ = try Self.runQueries(transaction)
          connection.releaseMemory()
          let count = Self.idleCount(connection)
          // The read transaction is still open and usable.
          return (count, try Self.runQueries(transaction))
        }
        _ = try connection.fetchAll("SELECT value FROM items") { $0[0].integerValue }
        connection.releaseMemory()
        return (inside, Self.idleCount(connection))
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
    func statementsOnLoanKeepWorkingAcrossARelease() throws {
      var owner = try Self.makeOwner(count: 20)
      let values = try owner.withReadConnection { connection in
        // Something else idle in the cache, so the release has something to finalize.
        _ = try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        var cursor = try connection.rowCursor("SELECT value FROM items ORDER BY value")
        var values: [Int64] = []
        while values.count < 5, let row = try cursor.next() {
          values.append(row[0].integerValue ?? -1)
        }
        connection.releaseMemory()
        #expect(Self.idleCount(connection) == 0)
        while let row = try cursor.next() {
          values.append(row[0].integerValue ?? -1)
        }
        return values
      }
      #expect(values == Array(1...20))
      // The cursor's statement was still valid, so it went back to the cache when the cursor ended.
      #expect(owner.statements.idleStatementCount == 1)

      let selected = try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          var insert = try transaction.prepare("INSERT INTO items (value) VALUES (?)")
          var select = try transaction.prepare("SELECT count(*) FROM items")
          try insert.execute(21)
          _ = try select.fetchAll { $0[0].integerValue }
          connection.releaseMemory()
          try insert.execute(22)
          return try select.fetchAll { $0[0].integerValue }
        }
      }
      #expect(selected == [22])
    }

    #if SystemSQLite
      @Test
      func releasingMemoryShrinksThePageCache() throws {
        #expect(SQLiteLibrary.system.connections.releaseMemory != nil)
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
          func total() throws -> Int64?? {
            try owner.read { transaction in
              try transaction.fetchOne("SELECT sum(length(payload)) FROM blobs") {
                $0[0].integerValue
              }
            }
          }
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
          #expect(try total() == 2_000_000)
          let before = cacheUsed()
          #expect(before > 1_000_000)
          owner.releaseMemory()
          #if canImport(Darwin)
            // Apple's build of SQLite manages its page cache itself, and keeps these pages.
            #expect(cacheUsed() <= before)
          #else
            #expect(cacheUsed() < before / 4)
          #endif
          // The pages are read again when they are needed.
          #expect(try total() == 2_000_000)
        }
      }
    #endif

    #if Turso
      @Test
      func tursoHasNoReleaseMemoryEntryPoint() {
        #expect(SQLiteLibrary.turso.connections.releaseMemory == nil)
      }
    #endif

    // MARK: - Drivers

    @Test
    func aQueueReleasesItsConnectionFromACancelledTask() async throws {
      let queue = try SQLiteQueue(path: .memory)
      try await queue.write { transaction in
        try transaction.execute("CREATE TABLE items (value INTEGER NOT NULL)")
        try transaction.execute("INSERT INTO items (value) VALUES (1), (2), (3)")
      }
      _ = try await queue.read { try Self.runQueries($0) }
      #expect(try await queue.readWithoutTransaction(Self.idleCount) > 0)

      let memoryReleasing: any OrbitMemoryReleasing = queue
      let release = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await memoryReleasing.releaseMemory()
      }
      await release.value
      #expect(try await queue.readWithoutTransaction(Self.idleCount) == 0)
      #expect(try await queue.read { try Self.runQueries($0) } == [3, 3, 1, 6])
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
        _ = try await connection.withReadConnection { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }

        suspension.suspend()
        await connection.releaseMemory()
        #expect(try await connection.withReadConnection(Self.idleCount) == 0)
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
