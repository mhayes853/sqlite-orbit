#if BuiltInSQLite
  import Foundation
  import StructuredQueries
  import Testing

  @testable import SQLiteOrbit

  private final class SQLiteCallCounters: Sendable {
    let prepared = Lock(0)
    let finalized = Lock(0)

    var preparedCount: Int { prepared.withLock { $0 } }
    var finalizedCount: Int { finalized.withLock { $0 } }
  }

  private func countingLibrary(_ counters: SQLiteCallCounters) -> SQLiteLibrary {
    let base = builtInTestLibrary
    var library = base
    library.statements.preparation.prepare = { connection, sql, byteCount, flags, statement, tail in
      let code = base.statements.preparation.prepare(
        connection,
        sql,
        byteCount,
        flags,
        statement,
        tail
      )
      if code == SQLiteResultCode.ok.rawValue, statement?.pointee != nil {
        counters.prepared.withLock { $0 += 1 }
      }
      return code
    }
    library.statements.execution.finalize = { statement in
      if statement != nil {
        counters.finalized.withLock { $0 += 1 }
      }
      return base.statements.execution.finalize(statement)
    }
    return library
  }

  private func scalar(_ connection: borrowing SQLiteHandle, _ sql: String) throws -> Int64 {
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
  func connectionOpensAndExecutesStatements() throws {
    let connection = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .default
    )

    try connection.execute(
      """
      CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
      INSERT INTO items (title) VALUES ('first');
      INSERT INTO items (title) VALUES ('second');
      """
    )

    #expect(try scalar(connection, "SELECT count(*) FROM items") == 2)
  }

  @Test
  func connectionAppliesItsConfiguredPragmas() throws {
    let enabled = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .default
    )
    #expect(try scalar(enabled, "PRAGMA foreign_keys") == 1)
    #expect(try scalar(enabled, "PRAGMA trusted_schema") == 0)

    var configuration = SQLiteConfiguration.default
    configuration.isForeignKeysEnabled = false
    configuration.setupSQL = ["PRAGMA application_id = 42"]
    let disabled = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    #expect(try scalar(disabled, "PRAGMA foreign_keys") == 0)
    #expect(try scalar(disabled, "PRAGMA application_id") == 42)
  }

  @Test
  func connectionEnforcesForeignKeysWhenConfigured() throws {
    let connection = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .default
    )
    try connection.execute(
      """
      CREATE TABLE lists (id INTEGER PRIMARY KEY);
      CREATE TABLE items (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists(id));
      """
    )

    #expect(throws: SQLiteError.self) {
      try connection.execute("INSERT INTO items (listID) VALUES (99)")
    }
  }

  @Test
  func statementCacheReusesAPreparedStatement() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    let connection = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    let afterOpen = counters.preparedCount

    let sql = "SELECT 1"
    for _ in 0..<10 {
      let statement = try connection.statements.checkOut(sql)
      connection.statements.checkIn(statement, sql: sql)
    }

    // Ten executions, one parse.
    #expect(counters.preparedCount == afterOpen + 1)
  }

  @Test
  func statementCacheLendsDistinctStatementsForOverlappingUse() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    let connection = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    let afterOpen = counters.preparedCount

    let sql = "SELECT 1"
    let first = try connection.statements.checkOut(sql)
    let second = try connection.statements.checkOut(sql)
    #expect(first.pointer != second.pointer)
    #expect(counters.preparedCount == afterOpen + 2)

    connection.statements.checkIn(first, sql: sql)
    connection.statements.checkIn(second, sql: sql)
  }

  @Test
  func statementCacheStaysWithinItsCapacity() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)
    configuration.maximumCachedStatements = 1

    let connection = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    let finalizedAfterOpen = counters.finalizedCount

    let kept = try connection.statements.checkOut("SELECT 1")
    connection.statements.checkIn(kept, sql: "SELECT 1")
    let overflow = try connection.statements.checkOut("SELECT 2")
    connection.statements.checkIn(overflow, sql: "SELECT 2")

    // The statement that did not fit was finalized rather than retained.
    #expect(counters.finalizedCount == finalizedAfterOpen + 1)
  }

  @Test
  func closingAConnectionFinalizesEveryStatementItPrepared() throws {
    let counters = SQLiteCallCounters()
    var configuration = SQLiteConfiguration.default
    configuration.library = countingLibrary(counters)

    do {
      let connection = try SQLiteHandle.open(
        path: ":memory:",
        flags: [.readWrite, .create, .memory, .noMutex],
        configuration: configuration
      )
      try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      for sql in ["SELECT 1", "SELECT 2", "SELECT 3"] {
        let statement = try connection.statements.checkOut(sql)
        connection.statements.checkIn(statement, sql: sql)
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
      _ = try SQLiteHandle.open(
        path: OrbitDatabasePath(path),
        flags: [.readWrite],
        configuration: .default
      )
    }
  }

  @Test
  func executeReportsTheFailingSQL() throws {
    let connection = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .default
    )
    let error = #expect(throws: SQLiteError.self) {
      try connection.execute("SELECT * FROM missing")
    }
    #expect(error?.sql == "SELECT * FROM missing")
    #expect(error?.message?.contains("missing") == true)
  }

  @Test
  func aFileBackedConnectionRoundTripsThroughAReopen() throws {
    let path = temporaryDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      let connection = try SQLiteHandle.open(
        path: OrbitDatabasePath(path),
        flags: [.readWrite, .create, .noMutex],
        configuration: .default
      )
      try connection.execute(
        """
        CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
        INSERT INTO items (title) VALUES ('persisted');
        """
      )
    }

    let reopened = try SQLiteHandle.open(
      path: OrbitDatabasePath(path),
      flags: [.readOnly, .noMutex],
      configuration: .default
    )
    #expect(try scalar(reopened, "SELECT count(*) FROM items") == 1)
  }

  @Test
  func connectionSetupsRunOnEveryConnectionAndCanFailTheOpen() throws {
    let installs = Lock(0)
    var configuration = SQLiteConfiguration.default
    configuration.connectionSetups = [
      SQLiteConnectionSetup { _ in
        installs.withLock { $0 += 1 }
        return SQLiteResultCode.ok.rawValue
      }
    ]

    _ = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    #expect(installs.withLock { $0 } == 1)

    configuration.connectionSetups.append(
      SQLiteConnectionSetup { _ in SQLiteResultCode.error.rawValue }
    )
    #expect(throws: SQLiteError.self) {
      _ = try SQLiteHandle.open(
        path: ":memory:",
        flags: [.readWrite, .create, .memory, .noMutex],
        configuration: configuration
      )
    }
  }

  @Test
  func aConnectionSetupThatThrowsFailsTheOpenWithItsOwnError() {
    struct SetupError: Error {}
    var configuration = SQLiteConfiguration.default
    configuration.connectionSetups = [SQLiteConnectionSetup { _ in throw SetupError() }]

    #expect(throws: SetupError.self) {
      _ = try SQLiteHandle.open(
        path: ":memory:",
        flags: [.readWrite, .create, .memory, .noMutex],
        configuration: configuration
      )
    }
  }

  @Test
  func aConnectionSetupIsHandedTheLibraryItsConnectionWasOpenedThrough() throws {
    let seenVersion = Lock<Int32?>(nil)
    var configuration = SQLiteConfiguration.default
    configuration.library.runtime.versionNumber = { 123_456 }
    configuration.connectionSetups = [
      SQLiteConnectionSetup { connection in
        seenVersion.withLock { $0 = connection.sqlite.runtime.versionNumber() }
        return SQLiteResultCode.ok.rawValue
      }
    ]

    _ = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    #expect(seenVersion.withLock { $0 } == 123_456)
  }

  @Test
  func connectionAccessExecutesQueryFragmentsWithBindings() throws {
    var configuration = SQLiteConfiguration.default
    configuration.connectionSetups = [
      SQLiteConnectionSetup { connection in
        try connection.execute("CREATE TABLE settings (value TEXT NOT NULL)")
        let value = "bound during setup"
        let query: QueryFragment = "INSERT INTO settings VALUES (\(bind: value))"
        try connection.execute(query)
        return SQLiteResultCode.ok.rawValue
      }
    ]

    let handle = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    #expect(
      try scalar(handle, "SELECT count(*) FROM settings WHERE value = 'bound during setup'") == 1
    )
  }

  @Test(
    arguments: [
      (Duration.seconds(5), Int32(5000)),
      (.milliseconds(250), 250),
      (.zero, 0),
      (.seconds(-1), 0),
      (.seconds(Int64.max), .max)
    ]
  )
  func aBusyTimeoutSaturatesRatherThanOverflowing(timeout: Duration, milliseconds: Int32) {
    var configuration = SQLiteConfiguration.default
    configuration.busyTimeout = timeout
    #expect(configuration.busyTimeoutMilliseconds == milliseconds)
  }
#endif
