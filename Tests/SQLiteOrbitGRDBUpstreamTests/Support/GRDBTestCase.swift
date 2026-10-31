// Adapted from GRDB 7.11.1 Tests/GRDBTests/GRDBTestCase.swift (MIT license, see LICENSE).
//
// The ported upstream tests subclass this harness. It keeps upstream's helper surface and
// configuration, with these differences:
// - SQLiteOrbitGRDB has no `onConnectionWillClose` hook or `Database.logError`, so the
//   statement-leak assertion and diagnostic capture are omitted.
// - SQL tracing records statements executed through the overlay's `Database`.
// - Upstream tests listed as runtime skips in upstream-manifest.txt are skipped in setUp.
// - Request statements are stepped through public fetching APIs instead of GRDB internals.

import Foundation
import SQLiteOrbitGRDB
import XCTest

class GRDBTestCase: XCTestCase {
  // The default configuration for tests
  var dbConfiguration: Configuration!

  // Builds a database queue based on dbConfiguration
  func makeDatabaseQueue(filename: String? = nil) throws -> DatabaseQueue {
    try makeDatabaseQueue(filename: filename, configuration: dbConfiguration)
  }

  // Builds a database queue
  func makeDatabaseQueue(filename: String? = nil, configuration: Configuration) throws
    -> DatabaseQueue
  {
    try FileManager.default.createDirectory(
      atPath: dbDirectoryPath,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let dbPath = (dbDirectoryPath as NSString)
      .appendingPathComponent(
        filename ?? ProcessInfo.processInfo.globallyUniqueString
      )
    let dbQueue = try DatabaseQueue(path: dbPath, configuration: configuration)
    try setup(dbQueue)
    return dbQueue
  }

  // Builds a database pool based on dbConfiguration
  func makeDatabasePool(filename: String? = nil) throws -> DatabasePool {
    try makeDatabasePool(filename: filename, configuration: dbConfiguration)
  }

  // Builds a database pool
  func makeDatabasePool(filename: String? = nil, configuration: Configuration) throws
    -> DatabasePool
  {
    try FileManager.default.createDirectory(
      atPath: dbDirectoryPath,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let dbPath = (dbDirectoryPath as NSString)
      .appendingPathComponent(
        filename ?? ProcessInfo.processInfo.globallyUniqueString
      )
    let dbPool = try DatabasePool(path: dbPath, configuration: configuration)
    try setup(dbPool)
    return dbPool
  }

  // Subclasses can override
  // Default implementation is empty.
  func setup(_ dbWriter: some DatabaseWriter) throws {
  }

  // The default path for database pool directory
  private var dbDirectoryPath: String!

  let _sqlQueriesMutex: Mutex<[String]> = Mutex([])

  // Automatically updated by default dbConfiguration
  var sqlQueries: [String] { _sqlQueriesMutex.load() }

  // Automatically updated by default dbConfiguration
  var lastSQLQuery: String? {
    // Skip comments that may be inserted by triggers and virtual tables.
    sqlQueries.last { !$0.hasPrefix("--") }
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    // `grdb_upstream.py run` sets this to find skipped tests that now pass.
    if ProcessInfo.processInfo.environment["GRDB_UPSTREAM_RUN_SKIPPED"] == nil,
      let reason = upstreamSkips[upstreamTestKey]
    {
      throw XCTSkip(reason)
    }
    if let reason = environmentSkipReason(upstreamTestKey) {
      throw XCTSkip(reason)
    }
  }

  // Upstream tests whose outcome depends on the SQLite build rather than on the overlay. These
  // cannot live in the manifest, whose skips are recomputed on the development machine.
  private func environmentSkipReason(_ key: String) -> String? {
    switch key {
    case "Issue1838Tests.test_interrupted_rollback":
      // GRDB works around this FTS5 bug by resetting every prepared statement through
      // `sqlite3_next_stmt`, which the core's library table does not expose. SQLite 3.54 passes;
      // 3.45 leaves the connection interrupted after the rollback.
      if Database.sqliteLibVersionNumber < 3_054_000 {
        return
          "SQLite \(Database.sqliteLibVersionNumber) keeps FTS5's interrupted state after a rollback"
      }
    case "DatabaseConfigurationTests.testAcceptsDoubleQuotedStringLiteralsTrue":
      // The overlay cannot enable SQLITE_DBCONFIG_DQS_DML, and SQLCipher is built without it.
      #if SQLCipher
        return "SQLCipher is built without double-quoted string literals"
      #endif
    default:
      break
    }
    return nil
  }

  // "Class.testName" on Linux; "-[Class testName]" on Apple platforms.
  private var upstreamTestKey: String {
    let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]"))
    return trimmed.replacingOccurrences(of: " ", with: ".")
  }

  override func setUp() {
    super.setUp()

    let dbPoolDirectoryName = "GRDBTestCase-\(ProcessInfo.processInfo.globallyUniqueString)"
    dbDirectoryPath = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent(
        dbPoolDirectoryName
      )
    do { try FileManager.default.removeItem(atPath: dbDirectoryPath) } catch {}

    dbConfiguration = Configuration()

    dbConfiguration.prepareDatabase { [_sqlQueriesMutex] db in
      db.trace { event in
        _sqlQueriesMutex.withLock {
          $0.append(event.expandedDescription)
        }
      }
    }

    clearSQLQueries()
  }

  override func tearDown() {
    super.tearDown()
    do { try FileManager.default.removeItem(atPath: dbDirectoryPath) } catch {}
  }

  func clearSQLQueries() {
    _sqlQueriesMutex.store([])
  }

  func assertNoError(file: StaticString = #file, line: UInt = #line, _ test: () throws -> Void) {
    do {
      try test()
    } catch {
      XCTFail("unexpected error: \(error)", file: file, line: line)
    }
  }

  func assertDidExecute(sql: String, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(sqlQueries.contains(sql), "Did not execute \(sql)", file: file, line: line)
  }

  func assert(
    _ record: some EncodableRecord,
    isEncodedIn row: Row,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    let recordDict = try record.databaseDictionary
    let rowDict = Dictionary(row, uniquingKeysWith: { (left, _) in left })
    XCTAssertEqual(recordDict, rowDict, file: file, line: line)
  }

  // Compare SQL strings (ignoring leading and trailing white space and semicolons.
  func assertEqualSQL(_ lhs: String, _ rhs: String, file: StaticString = #file, line: UInt = #line)
  {
    // Trim white space and ";"
    let cs = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))
    XCTAssertEqual(
      lhs.trimmingCharacters(in: cs),
      rhs.trimmingCharacters(in: cs),
      file: file,
      line: line
    )
  }

  // Compare SQL strings (ignoring leading and trailing white space and semicolons.
  func assertEqualSQL(
    _ db: Database,
    _ request: some FetchRequest,
    _ sql: String,
    file: StaticString = #file,
    line: UInt = #line
  )
    throws
  {
    _ = try Row.fetchCursor(request.makeStatement(db)).next()
    assertEqualSQL(lastSQLQuery!, sql, file: file, line: line)
  }

  // Compare SQL strings.
  func assertEqualSQL(
    _ db: Database,
    _ expression: some SQLExpressible,
    _ sql: String,
    file: StaticString = #file,
    line: UInt = #line
  )
    throws
  {
    let request: SQLRequest<Row> = "SELECT \(expression)"
    try assertEqualSQL(db, request, "SELECT \(sql)", file: file, line: line)
  }

  // Compare SQL strings (ignoring leading and trailing white space and semicolons.
  func assertEqualSQL(
    _ databaseReader: some DatabaseReader,
    _ request: some FetchRequest,
    _ sql: String,
    file: StaticString = #file,
    line: UInt = #line
  )
    throws
  {
    try databaseReader.unsafeRead { db in
      try assertEqualSQL(db, request, sql, file: file, line: line)
    }
  }

  func sql(
    _ databaseReader: some DatabaseReader,
    _ request: some FetchRequest
  )
    -> String
  {
    try! databaseReader.unsafeRead { db in
      _ = try Row.fetchCursor(request.makeStatement(db)).next()
      return lastSQLQuery!
    }
  }
}

let testBundle = Bundle.module

extension FetchRequest {
  /// Turn request into a statement
  func makeStatement(_ db: Database) throws -> Statement {
    try makePreparedRequest(db, forSingleResult: false).statement
  }

  /// Turn request into SQL and arguments
  func build(_ db: Database) throws -> (sql: String, arguments: StatementArguments) {
    let statement = try makePreparedRequest(db, forSingleResult: false).statement
    return (sql: statement.sql, arguments: statement.arguments)
  }
}
