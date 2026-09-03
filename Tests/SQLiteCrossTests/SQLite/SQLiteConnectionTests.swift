#if SystemSQLite
  import Foundation
  import Synchronization
  import Testing

  @testable import SQLiteCross

  /// Counts the statement entry points, so tests can assert on caching rather than guess at it.
  private final class SQLiteCallCounters: Sendable {
    let prepared = Mutex(0)
    let finalized = Mutex(0)

    var preparedCount: Int { prepared.withLock { $0 } }
    var finalizedCount: Int { finalized.withLock { $0 } }
  }

  private func countingLibrary(_ counters: SQLiteCallCounters) -> SQLiteLibrary {
    let base = SQLiteLibrary.system
    var library = base
    library.prepare_v3 = { connection, sql, byteCount, flags, statement, tail in
      let code = base.prepare_v3(connection, sql, byteCount, flags, statement, tail)
      if code == SQLiteResultCode.ok.rawValue, statement?.pointee != nil {
        counters.prepared.withLock { $0 += 1 }
      }
      return code
    }
    library.finalize = { statement in
      if statement != nil {
        counters.finalized.withLock { $0 += 1 }
      }
      return base.finalize(statement)
    }
    return library
  }

  /// Reads a single integer, using the library table directly so the test does not depend on the
  /// cursor types that do not exist yet.
  private func scalar(_ connection: borrowing SQLiteHandle, _ sql: String) throws -> Int64 {
    let library = connection.library
    var statement: OpaquePointer?
    let code = sql.withCString {
      library.pointee.prepare_v3(connection.pointer, $0, -1, 0, &statement, nil)
    }
    try #require(code == SQLiteResultCode.ok.rawValue)
    defer { _ = library.pointee.finalize(statement) }
    try #require(library.pointee.step(statement) == SQLiteResultCode.row.rawValue)
    return library.pointee.column_int64(statement, 0)
  }

  private func temporaryDatabasePath() -> String {
    NSTemporaryDirectory() + "sqlite-cross-\(UUID().uuidString).sqlite"
  }

  @Test
  func connectionOpensExecutesAndReportsMutations() throws {
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

    #expect(connection.changes() == 1)
    #expect(connection.lastInsertRowID() == 2)
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
    #expect(first != second)
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
    let path = NSTemporaryDirectory() + "sqlite-cross-missing-\(UUID().uuidString)/db.sqlite"
    #expect(throws: SQLiteError.self) {
      _ = try SQLiteHandle.open(path: path, flags: [.readWrite], configuration: .default)
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
        path: path,
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
      path: path,
      flags: [.readOnly, .noMutex],
      configuration: .default
    )
    #expect(try scalar(reopened, "SELECT count(*) FROM items") == 1)
  }
#endif
