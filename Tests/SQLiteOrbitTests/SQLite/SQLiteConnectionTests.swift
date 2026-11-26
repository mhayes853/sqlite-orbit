#if BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  /// Counts the statements a connection prepares and finalizes.
  private struct SQLiteCallCounters: Sendable {
    let prepared = TestCounter()
    let preparedPersistent = TestCounter()
    let finalized = TestCounter()

    var preparedCount: Int { self.prepared.value }
    var preparedPersistentCount: Int { self.preparedPersistent.value }
    var finalizedCount: Int { self.finalized.value }
  }

  private func countingLibrary(_ counters: SQLiteCallCounters) -> SQLiteLibrary {
    let base = builtInTestLibrary
    var library = base
    library.statements.preparation.prepare = LibraryHooks.prepare {
      connection,
      sql,
      byteCount,
      flags,
      statement,
      tail in
      let code = base.statements.preparation.prepare(
        connection,
        sql,
        byteCount,
        flags,
        statement,
        tail
      )
      if code == SQLiteResultCode.ok.rawValue, statement?.pointee != nil {
        counters.prepared.increment()
        if flags & SQLitePrepareFlags.persistent.rawValue != 0 {
          counters.preparedPersistent.increment()
        }
      }
      return code
    }
    library.statements.execution.finalize = LibraryHooks.finalize { statement in
      if statement != nil {
        counters.finalized.increment()
      }
      return base.statements.execution.finalize(statement)
    }
    return library
  }

  private func openInMemory(
    _ configuration: SQLiteConfiguration = .default
  ) throws -> SQLiteConnection {
    try SQLiteConnection.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
  }

  private func scalar(_ connection: borrowing SQLiteConnection, _ sql: String) throws -> Int64 {
    let library = connection.library
    var statement: OpaquePointer?
    let code = sql.withCString {
      library.pointee.statements.preparation.prepare(connection.pointer, $0, -1, 0, &statement, nil)
    }
    try #require(code == SQLiteResultCode.ok.rawValue)
    defer { _ = library.pointee.statements.execution.finalize(statement) }
    try #require(
      library.pointee.statements.execution.step(statement) == SQLiteResultCode.row.rawValue
    )
    return library.pointee.columns.int64(statement, 0)
  }

  @Test
  func connectionAppliesItsConfiguredPragmas() throws {
    let enabled = try openInMemory()
    #expect(try scalar(enabled, "PRAGMA foreign_keys") == 1)
    #expect(try scalar(enabled, "PRAGMA trusted_schema") == 0)

    var configuration = SQLiteConfiguration.default
    configuration.isForeignKeysEnabled = false
    configuration.setups = [.sql("PRAGMA application_id = 42")]
    let disabled = try openInMemory(configuration)
    #expect(try scalar(disabled, "PRAGMA foreign_keys") == 0)
    #expect(try scalar(disabled, "PRAGMA application_id") == 42)
  }

  /// Runs `body` with an in-memory connection whose library counts what it prepares and
  /// finalizes, and whose cache keeps at most `maximumCachedStatements`.
  private func withCountingConnection(
    maximumCachedStatements: Int = .max,
    _ body: (borrowing SQLiteConnection, SQLiteCallCounters) throws -> Void
  ) throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = maximumCachedStatements
    let connection = try openInMemory(configuration)
    try body(connection, counters)
  }

  /// Runs each of `sqls` through the cache once, in order.
  private func use(_ sqls: [String], on connection: borrowing SQLiteConnection) throws {
    for sql in sqls {
      let statement = try connection.statements.checkOut(sql)
      connection.statements.checkIn(statement)
    }
  }

  @Test(.libraryHooks)
  func statementCacheReusesACheckedInStatementAndLendsAnotherForOverlappingUse() throws {
    try withCountingConnection { connection, counters in
      let afterOpen = counters.preparedCount
      // Ten executions, one parse.
      try use(Array(repeating: "SELECT 1", count: 10), on: connection)
      #expect(counters.preparedCount == afterOpen + 1)

      // Two at once cannot share one statement, so the second is prepared anew.
      let first = try connection.statements.checkOut("SELECT 1")
      let second = try connection.statements.checkOut("SELECT 1")
      #expect(first.pointer != second.pointer)
      #expect(counters.preparedCount == afterOpen + 2)
      connection.statements.checkIn(first)
      connection.statements.checkIn(second)
    }
  }

  /// A run of statements through a cache of some capacity, and which of them it should then
  /// hold: the most recently used, however they got there.
  struct SQLiteStatementCacheHistory: Sendable, CustomTestStringConvertible {
    let capacity: Int
    let history: [Int]
    let cached: [Int]
    let evicted: [Int]
    let testDescription: String
  }

  @Test(
    .libraryHooks,
    arguments: [
      SQLiteStatementCacheHistory(
        capacity: 2,
        history: [1, 2, 3],
        cached: [2, 3],
        evicted: [1],
        testDescription: "a full cache evicts the least recently used"
      ),
      SQLiteStatementCacheHistory(
        capacity: 2,
        history: [1, 2, 1, 3],
        cached: [1, 3],
        evicted: [2],
        testDescription: "reuse outlives an older statement"
      ),
      SQLiteStatementCacheHistory(
        capacity: .max,
        history: [1, 2, 1, 2, 1, 2, 1, 2, 1, 2],
        cached: [1, 2],
        evicted: [],
        testDescription: "alternating between two reuses both"
      ),
      SQLiteStatementCacheHistory(
        capacity: 1,
        history: [1, 2],
        cached: [2],
        evicted: [1],
        testDescription: "the most recent statement counts toward the capacity"
      ),
      SQLiteStatementCacheHistory(
        capacity: 2,
        history: [2, 1, 1, 3],
        cached: [1, 3],
        evicted: [2],
        testDescription: "a statement leaving the most recent slot is evicted in its turn"
      )
    ]
  )
  func aStatementCacheKeepsTheMostRecentlyUsedStatements(_ run: SQLiteStatementCacheHistory) throws
  {
    try withCountingConnection(maximumCachedStatements: run.capacity) { connection, counters in
      let select = { (values: [Int]) in values.map { "SELECT \($0)" } }
      let afterOpen = (counters.preparedCount, counters.finalizedCount)
      try use(select(run.history), on: connection)
      #expect(connection.statements.idleStatementCount == run.cached.count)
      // Each distinct statement was prepared once, and all but those kept were finalized.
      let prepared = counters.preparedCount
      #expect(prepared - afterOpen.0 == Set(run.history).count)
      #expect(counters.finalizedCount - afterOpen.1 == Set(run.history).count - run.cached.count)

      try use(select(run.cached), on: connection)
      #expect(counters.preparedCount == prepared)
      try use(select(run.evicted), on: connection)
      #expect(counters.preparedCount == prepared + run.evicted.count)
    }
  }

  @Test
  func theDefaultStatementCacheHasNoLimit() throws {
    #expect(SQLiteConfiguration.default.maximumCachedStatements == .max)
    let connection = try openInMemory()
    try use((0..<500).map { "SELECT \($0)" }, on: connection)
    #expect(connection.statements.idleStatementCount == 500)
  }

  @Test(.libraryHooks)
  func aStatementCacheWithoutCapacityKeepsNothing() throws {
    try withCountingConnection(maximumCachedStatements: 0) { connection, counters in
      let prepared = counters.preparedCount
      let persistent = counters.preparedPersistentCount
      let finalized = counters.finalizedCount
      try use(["SELECT 1", "SELECT 1", "SELECT 2"], on: connection)
      #expect(connection.statements.idleStatementCount == 0)
      #expect(counters.preparedCount == prepared + 3)
      #expect(counters.finalizedCount == finalized + 3)
      // Nothing is kept, so nothing is prepared as though it would be.
      #expect(counters.preparedPersistentCount == persistent)
    }
  }

  @Test(.libraryHooks)
  func invalidatingTheStatementCacheFinalizesTheMostRecentStatement() throws {
    try withCountingConnection { connection, counters in
      try use(["SELECT 1", "SELECT 2"], on: connection)
      let prepared = counters.preparedCount
      let finalized = counters.finalizedCount
      connection.statements.invalidate()
      #expect(connection.statements.idleStatementCount == 0)
      #expect(counters.finalizedCount == finalized + 2)
      try use(["SELECT 2"], on: connection)
      #expect(counters.preparedCount == prepared + 1)
    }
  }

  @Test(.libraryHooks)
  func aStatementLentWhileTheSameSQLWasCheckedInIsFinalized() throws {
    try withCountingConnection { connection, counters in
      try use(["SELECT 1"], on: connection)
      let finalized = counters.finalizedCount

      // Two uses at once, given back while the first is still the most recent statement.
      let first = try connection.statements.checkOut("SELECT 1")
      let second = try connection.statements.checkOut("SELECT 1")
      connection.statements.checkIn(second)
      connection.statements.checkIn(first)
      #expect(counters.finalizedCount == finalized + 1)
      #expect(connection.statements.idleStatementCount == 1)

      // And given back after another statement moved the second out of that slot.
      let third = try connection.statements.checkOut("SELECT 1")
      let fourth = try connection.statements.checkOut("SELECT 1")
      connection.statements.checkIn(fourth)
      try use(["SELECT 2"], on: connection)
      connection.statements.checkIn(third)
      #expect(counters.finalizedCount == finalized + 2)
      #expect(connection.statements.idleStatementCount == 2)
      #expect(third.pointer != fourth.pointer)

      let prepared = counters.preparedCount
      let fifth = try connection.statements.checkOut("SELECT 1")
      #expect(fifth.pointer == fourth.pointer)
      connection.statements.checkIn(fifth)
      #expect(counters.preparedCount == prepared)
    }
  }

  @Test(.libraryHooks)
  func aQueryBuiltFromTheSameLiteralFindsTheMostRecentStatement() throws {
    try withCountingConnection { connection, counters in
      func query(_ value: Int, column: String) -> SQL {
        "SELECT \(value) AS \(quote: column)"
      }
      connection.statements.checkIn(try connection.statements.checkOut(query(0, column: "a")))
      let prepared = counters.preparedCount
      for value in 1..<5 {
        connection.statements.checkIn(try connection.statements.checkOut(query(value, column: "a")))
      }
      #expect(counters.preparedCount == prepared)
      // The same shape built from different text is a different statement.
      connection.statements.checkIn(try connection.statements.checkOut(query(0, column: "b")))
      #expect(counters.preparedCount == prepared + 1)
    }
  }

  @Test(.libraryHooks)
  func closingAConnectionFinalizesEveryStatementItPrepared() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    do {
      let connection = try openInMemory(configuration)
      try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      try use(["SELECT 1", "SELECT 2", "SELECT 3"], on: connection)
      #expect(counters.preparedCount > counters.finalizedCount)
    }

    // The connection's `deinit` is the only thing that could have balanced these.
    #expect(counters.preparedCount == counters.finalizedCount)
  }

  @Test
  func aMissingDatabaseAndAFailingStatementAreReported() throws {
    let path = temporaryDatabasePath("missing") + "/db.sqlite"
    #expect(throws: SQLiteError.self) {
      _ = try SQLiteConnection.open(
        path: OrbitDatabasePath(path),
        flags: [.readWrite],
        configuration: .default
      )
    }

    // A failing statement is reported along with its SQL.
    let connection = try openInMemory()
    let error = #expect(throws: SQLiteError.self) {
      try connection.execute("SELECT * FROM missing")
    }
    #expect(error?.sql == "SELECT * FROM missing")
    #expect(error?.message?.contains("missing") == true)
  }

  @Test
  func setupsRunOnEveryConnectionWithItsLibraryAndCanFailTheOpen() throws {
    let installs = TestCounter()
    var configuration = SQLiteConfiguration.default
    configuration.setups = [
      SQLiteSetup { _ in
        installs.increment()
      }
    ]

    _ = try openInMemory(configuration)
    #expect(installs.value == 1)

    var failingSQL = configuration
    failingSQL.setups.append(.sql("SELECT * FROM missing_setup_table"))
    #expect(throws: SQLiteError.self) {
      _ = try openInMemory(failingSQL)
    }

    // A setup that throws fails the open with its own error rather than a SQLite one.
    var throwing = configuration
    throwing.setups.append(SQLiteSetup { _ in throw TestError() })
    #expect(throws: TestError()) {
      _ = try openInMemory(throwing)
    }

    // A setup is handed the library its connection was opened through.
    let seenVersion = Lock<Int32?>(nil)
    var libraryConfiguration = SQLiteConfiguration.default
    libraryConfiguration.library.runtime.versionNumber = { 123_456 }
    libraryConfiguration.setups = [
      SQLiteSetup { connection in
        seenVersion.withLock { $0 = connection.sqlite.runtime.versionNumber() }
      }
    ]

    _ = try openInMemory(libraryConfiguration)
    #expect(seenVersion.withLock { $0 } == 123_456)

    // Setups execute SQL, with bindings, on the connection they are handed.
    var sqlConfiguration = SQLiteConfiguration.default
    let value = "bound during setup"
    sqlConfiguration.setups = [
      .script(
        "CREATE TABLE settings (value TEXT NOT NULL); INSERT INTO settings VALUES ('first');"
      ),
      .sql("INSERT INTO settings VALUES (\(value))"),
      SQLiteSetup { connection in
        try connection.execute("UPDATE settings SET value = 'callback' WHERE value = 'first'")
      },
      .sql("DELETE FROM settings WHERE value = 'callback'")
    ]

    let handle = try openInMemory(sqlConfiguration)
    #expect(try scalar(handle, "SELECT count(*) FROM settings") == 1)
    #expect(
      try scalar(handle, "SELECT count(*) FROM settings WHERE value = 'bound during setup'") == 1
    )
  }

  @Test(
    arguments: [
      (SQLiteBusyPolicy.timeout(.seconds(5)), Int32(5000)),
      (.timeout(.milliseconds(250)), 250),
      (.timeout(.zero), 0),
      (.timeout(.seconds(-1)), 0),
      (.timeout(.seconds(2_147_483)), 2_147_483_000),
      (.timeout(.milliseconds(2_147_483_646)), 2_147_483_646),
      (.timeout(.milliseconds(2_147_483_647)), .max),
      (.timeout(.milliseconds(2_147_483_648)), .max),
      (.timeout(.seconds(Int64.max)), .max),
      (.waitIndefinitely, .max)
    ]
  )
  func aBusyTimeoutSaturatesRatherThanOverflowing(
    timeout: SQLiteBusyPolicy,
    milliseconds: Int32
  ) {
    #expect(timeout.timeoutMilliseconds == milliseconds)
  }
#endif
