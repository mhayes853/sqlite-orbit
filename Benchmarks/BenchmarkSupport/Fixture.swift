import CSQLiteBenchmark
import Foundation

// The fixture and sizes of GRDB's performance suite, so results can be read against its own: a
// table of ten integer columns, read 200,000 rows at a time and written 50,000 rows at a time.
public enum Fixture {
  public static let fetchedRowCount = 200_000
  public static let insertedRowCount = 50_000

  public static let createItemTableSQL =
    "CREATE TABLE item (i0 INT, i1 INT, i2 INT, i3 INT, i4 INT, i5 INT, i6 INT, i7 INT, i8 INT, i9 INT)"
  public static let insertItemSQL =
    "INSERT INTO item (i0, i1, i2, i3, i4, i5, i6, i7, i8, i9) VALUES (?,?,?,?,?,?,?,?,?,?)"

  public static let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sqlite-orbit-benchmarks", isDirectory: true)

  /// The path of a database holding `fetchedRowCount` items, where item `n` stores `n` in every
  /// column, generating it on first use.
  ///
  /// It is written with the C API alone, so that no library under measurement shapes the file the
  /// others read.
  public static func fetchDatabasePath() throws -> String {
    let path = directory.appendingPathComponent("fetch-\(fetchedRowCount).sqlite").path
    if try itemCount(at: path) == fetchedRowCount {
      return path
    }
    removeDatabase(at: path)
    try withConnection(at: path) { connection in
      try execute(connection, createItemTableSQL)
      try execute(connection, "BEGIN")
      var statement: OpaquePointer?
      try check(connection, sqlite3_prepare_v2(connection, insertItemSQL, -1, &statement, nil))
      defer { sqlite3_finalize(statement) }
      for i in Int64(0)..<Int64(fetchedRowCount) {
        sqlite3_reset(statement)
        for column in Int32(1)...10 {
          sqlite3_bind_int64(statement, column, i)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
          throw BenchmarkError(message: String(cString: sqlite3_errmsg(connection)))
        }
      }
      try execute(connection, "COMMIT")
    }
    return path
  }

  /// A path no database occupies yet, for a benchmark that writes one of its own.
  public static func scratchDatabasePath(_ name: String) -> String {
    let path = directory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite").path
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return path
  }

  /// Removes a database along with any journal files beside it.
  public static func removeDatabase(at path: String) {
    for suffix in ["", "-journal", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: path + suffix)
    }
  }

  /// The number of items in the database at `path`, or `nil` when it has no item table.
  public static func itemCount(at path: String) throws -> Int? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return try withConnection(at: path) { connection in
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(connection, "SELECT count(*) FROM item", -1, &statement, nil)
          == SQLITE_OK
      else { return nil }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  private static func withConnection<Result>(
    at path: String,
    _ body: (OpaquePointer?) throws -> Result
  ) throws -> Result {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var connection: OpaquePointer?
    defer { sqlite3_close_v2(connection) }
    try check(
      connection,
      sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    )
    return try body(connection)
  }

  private static func execute(_ connection: OpaquePointer?, _ sql: String) throws {
    try check(connection, sqlite3_exec(connection, sql, nil, nil, nil))
  }

  private static func check(_ connection: OpaquePointer?, _ code: Int32) throws {
    guard code == SQLITE_OK else {
      throw BenchmarkError(message: String(cString: sqlite3_errmsg(connection)))
    }
  }
}

/// A benchmark's failure to set up, or to find the result it should have produced.
public struct BenchmarkError: Error, CustomStringConvertible {
  public let message: String

  public init(message: String) {
    self.message = message
  }

  public var description: String { message }
}
