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

  @Test(.libraryHooks)
  func statementCacheReusesACheckedInStatementAndLendsAnotherForOverlappingUse() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    let connection = try openInMemory(configuration)
    let afterOpen = counters.preparedCount

    let sql = "SELECT 1"
    for _ in 0..<10 {
      let statement = try connection.statements.checkOut(sql)
      connection.statements.checkIn(statement)
    }

    // Ten executions, one parse.
    #expect(counters.preparedCount == afterOpen + 1)

    // Two at once cannot share one statement, so the second is prepared anew.
    let first = try connection.statements.checkOut(sql)
    let second = try connection.statements.checkOut(sql)
    #expect(first.pointer != second.pointer)
    #expect(counters.preparedCount == afterOpen + 2)
    connection.statements.checkIn(first)
    connection.statements.checkIn(second)
  }

  @Test(.libraryHooks)
  func statementCacheStaysWithinItsCapacity() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = 1

    let connection = try openInMemory(configuration)
    let finalizedAfterOpen = counters.finalizedCount

    let kept = try connection.statements.checkOut("SELECT 1")
    connection.statements.checkIn(kept)
    let overflow = try connection.statements.checkOut("SELECT 2")
    connection.statements.checkIn(overflow)

    // The statement that did not fit was finalized rather than retained.
    #expect(counters.finalizedCount == finalizedAfterOpen + 1)
  }

  /// Runs each of `sqls` through the cache once, in order.
  private func use(_ sqls: [String], on connection: borrowing SQLiteConnection) throws {
    for sql in sqls {
      let statement = try connection.statements.checkOut(sql)
      connection.statements.checkIn(statement)
    }
  }

  @Test(.libraryHooks)
  func aFullStatementCacheEvictsTheLeastRecentlyUsedStatement() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = 2

    let connection = try openInMemory(configuration)
    try use(["SELECT 1", "SELECT 2", "SELECT 3"], on: connection)
    #expect(connection.statements.idleStatementCount == 2)

    // The two most recent are still cached, and the first was finalized to make room.
    let prepared = counters.preparedCount
    let finalized = counters.finalizedCount
    try use(["SELECT 2", "SELECT 3"], on: connection)
    #expect(counters.preparedCount == prepared)
    try use(["SELECT 1"], on: connection)
    #expect(counters.preparedCount == prepared + 1)
    // Bringing it back evicted `SELECT 2`, the least recently used of the two.
    #expect(counters.finalizedCount == finalized + 1)
    try use(["SELECT 3", "SELECT 1"], on: connection)
    #expect(counters.preparedCount == prepared + 1)
  }

  @Test(.libraryHooks)
  func aRecentlyUsedStatementOutlivesAnOlderOne() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = 2

    let connection = try openInMemory(configuration)
    // `SELECT 1` was cached first, but reusing it makes `SELECT 2` the one to go.
    try use(["SELECT 1", "SELECT 2", "SELECT 1", "SELECT 3"], on: connection)

    let prepared = counters.preparedCount
    try use(["SELECT 1", "SELECT 3"], on: connection)
    #expect(counters.preparedCount == prepared)
    try use(["SELECT 2"], on: connection)
    #expect(counters.preparedCount == prepared + 1)
  }

  @Test(.libraryHooks)
  func statementCacheKeepsAtMostItsCapacityOfTheLatestStatements() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = 3

    let connection = try openInMemory(configuration)
    let sqls = (0..<10).map { "SELECT \($0)" }
    let finalizedAfterOpen = counters.finalizedCount
    try use(sqls, on: connection)
    #expect(connection.statements.idleStatementCount == 3)
    #expect(counters.finalizedCount == finalizedAfterOpen + 7)

    let prepared = counters.preparedCount
    try use(Array(sqls.suffix(3)), on: connection)
    #expect(counters.preparedCount == prepared)
  }

  @Test
  func theDefaultStatementCacheHoldsSixtyFourStatements() throws {
    #expect(SQLiteConfiguration.default.maximumCachedStatements == 64)
    let connection = try openInMemory()
    try use((0..<100).map { "SELECT \($0)" }, on: connection)
    #expect(connection.statements.idleStatementCount == 64)
  }

  @Test(.libraryHooks)
  func aStatementCacheWithoutCapacityKeepsNothing() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = 0

    let connection = try openInMemory(configuration)
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

  @Test(.libraryHooks)
  func alternatingBetweenTwoStatementsReusesBoth() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    let connection = try openInMemory(configuration)
    let prepared = counters.preparedCount
    let finalized = counters.finalizedCount
    // Each moves the other out of the slot for the most recent statement, and back.
    for _ in 0..<5 {
      try use(["SELECT 1", "SELECT 2"], on: connection)
    }
    #expect(counters.preparedCount == prepared + 2)
    #expect(counters.finalizedCount == finalized)
    #expect(connection.statements.idleStatementCount == 2)
  }

  @Test(.libraryHooks)
  func theMostRecentStatementCountsTowardTheCapacity() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = 1

    let connection = try openInMemory(configuration)
    let finalized = counters.finalizedCount
    try use(["SELECT 1", "SELECT 2"], on: connection)
    #expect(connection.statements.idleStatementCount == 1)
    #expect(counters.finalizedCount == finalized + 1)

    let prepared = counters.preparedCount
    try use(["SELECT 2"], on: connection)
    #expect(counters.preparedCount == prepared)
    try use(["SELECT 1"], on: connection)
    #expect(counters.preparedCount == prepared + 1)
  }

  @Test(.libraryHooks)
  func aStatementLeavingTheMostRecentSlotIsEvictedInItsTurn() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = 2

    let connection = try openInMemory(configuration)
    // `SELECT 2` is the most recent, then `SELECT 1` takes its place and leaves it the oldest.
    try use(["SELECT 2", "SELECT 1"], on: connection)
    let lent = try connection.statements.checkOut("SELECT 1")
    connection.statements.checkIn(lent)

    let prepared = counters.preparedCount
    let finalized = counters.finalizedCount
    try use(["SELECT 3"], on: connection)
    #expect(counters.finalizedCount == finalized + 1)
    try use(["SELECT 1", "SELECT 3"], on: connection)
    #expect(counters.preparedCount == prepared + 1)
    try use(["SELECT 2"], on: connection)
    #expect(counters.preparedCount == prepared + 2)
  }

  @Test(.libraryHooks)
  func invalidatingTheStatementCacheFinalizesTheMostRecentStatement() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    let connection = try openInMemory(configuration)
    try use(["SELECT 1", "SELECT 2"], on: connection)
    let prepared = counters.preparedCount
    let finalized = counters.finalizedCount
    connection.statements.invalidate()
    #expect(connection.statements.idleStatementCount == 0)
    #expect(counters.finalizedCount == finalized + 2)
    try use(["SELECT 2"], on: connection)
    #expect(counters.preparedCount == prepared + 1)
  }

  @Test(.libraryHooks)
  func aStatementLentWhileTheSameSQLWasCheckedInIsFinalized() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    let connection = try openInMemory(configuration)
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

  @Test(.libraryHooks)
  func aQueryBuiltFromTheSameLiteralFindsTheMostRecentStatement() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    let connection = try openInMemory(configuration)
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

  @Test(.libraryHooks)
  func closingAConnectionFinalizesEveryStatementItPrepared() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    do {
      let connection = try openInMemory(configuration)
      try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      for sql in ["SELECT 1", "SELECT 2", "SELECT 3"] {
        let statement = try connection.statements.checkOut(sql)
        connection.statements.checkIn(statement)
      }
      #expect(counters.preparedCount > counters.finalizedCount)
    }

    // The connection's `deinit` is the only thing that could have balanced these.
    #expect(counters.preparedCount == counters.finalizedCount)
  }

  @Test
  func openingReportsAnErrorRatherThanCreatingAMissingDatabase() throws {
    let path = temporaryDatabasePath("missing") + "/db.sqlite"
    #expect(throws: SQLiteError.self) {
      _ = try SQLiteConnection.open(
        path: OrbitDatabasePath(path),
        flags: [.readWrite],
        configuration: .default
      )
    }
  }

  @Test
  func executeReportsTheFailingSQL() throws {
    let connection = try openInMemory()
    let error = #expect(throws: SQLiteError.self) {
      try connection.execute("SELECT * FROM missing")
    }
    #expect(error?.sql == "SELECT * FROM missing")
    #expect(error?.message?.contains("missing") == true)
  }

  @Test
  func setupsRunOnEveryConnectionAndCanFailTheOpen() throws {
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
  }

  @Test
  func aConnectionSetupIsHandedTheLibraryItsConnectionWasOpenedThrough() throws {
    let seenVersion = Lock<Int32?>(nil)
    var configuration = SQLiteConfiguration.default
    configuration.library.runtime.versionNumber = { 123_456 }
    configuration.setups = [
      SQLiteSetup { connection in
        seenVersion.withLock { $0 = connection.sqlite.runtime.versionNumber() }
      }
    ]

    _ = try openInMemory(configuration)
    #expect(seenVersion.withLock { $0 } == 123_456)
  }

  @Test
  func connectionAccessExecutesSQLWithBindings() throws {
    var configuration = SQLiteConfiguration.default
    let value = "bound during setup"
    configuration.setups = [
      .script(
        "CREATE TABLE settings (value TEXT NOT NULL); INSERT INTO settings VALUES ('first');"
      ),
      .sql("INSERT INTO settings VALUES (\(value))"),
      SQLiteSetup { connection in
        try connection.execute("UPDATE settings SET value = 'callback' WHERE value = 'first'")
      },
      .sql("DELETE FROM settings WHERE value = 'callback'")
    ]

    let handle = try openInMemory(configuration)
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
