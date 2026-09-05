final class SQLiteStatementCache {
  private let library: UnsafePointer<SQLiteLibrary>
  private let connection: OpaquePointer
  private let capacity: Int

  private var idle: [String: OpaquePointer] = [:]

  init(library: UnsafePointer<SQLiteLibrary>, connection: OpaquePointer, capacity: Int) {
    self.library = library
    self.connection = connection
    self.capacity = max(0, capacity)
  }

  func prepare(_ sql: String) throws -> OpaquePointer {
    try prepare(sql, flags: 0)
  }

  func checkOut(_ sql: String) throws -> OpaquePointer {
    if let statement = idle.removeValue(forKey: sql) {
      return statement
    }
    // A cache that keeps nothing gains nothing from hinting that the statement will be reused.
    return try prepare(sql, flags: capacity > 0 ? SQLitePrepareFlags.persistent.rawValue : 0)
  }

  private func prepare(_ sql: String, flags: UInt32) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let code = sql.withCString {
      library.pointee.prepare_v3(connection, $0, -1, flags, &statement, nil)
    }
    guard code == SQLiteResultCode.ok.rawValue, let statement else {
      if let statement {
        _ = library.pointee.finalize(statement)
      }
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
    }
    return statement
  }

  func checkIn(_ statement: OpaquePointer, sql: String) {
    _ = library.pointee.reset(statement)
    _ = library.pointee.clear_bindings(statement)
    guard idle.count < capacity, idle[sql] == nil else {
      _ = library.pointee.finalize(statement)
      return
    }
    idle[sql] = statement
  }

  func finalizeAll() {
    for statement in idle.values {
      _ = library.pointee.finalize(statement)
    }
    idle.removeAll()
  }
}
