import CSQLiteBenchmark

/// A raw C connection, closed when released.
public final class RawSQLiteConnection {
  public let handle: OpaquePointer

  public init(path: String) throws {
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard code == SQLITE_OK, let handle else {
      sqlite3_close_v2(handle)
      throw BenchmarkError(message: "Cannot open \(path): \(code)")
    }
    self.handle = handle
  }

  deinit {
    sqlite3_close_v2(handle)
  }

  public var error: BenchmarkError {
    BenchmarkError(message: String(cString: sqlite3_errmsg(handle)))
  }

  public func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error }
  }

  public func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw error
    }
    return statement
  }

  /// Steps a statement that returns no rows.
  public func step(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
  }

  /// The integer columns of the first row `sql` returns.
  public func integers(_ sql: String) throws -> [Int64] {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw error }
    return (0..<sqlite3_column_count(statement)).map { sqlite3_column_int64(statement, $0) }
  }
}
