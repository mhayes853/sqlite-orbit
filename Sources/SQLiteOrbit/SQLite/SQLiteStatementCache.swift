/// The prepared statements a connection keeps for reuse.
///
/// Structured Queries builds the same SQL text on every call, so preparing it once and resetting it
/// afterward is the difference between one parse per query and one parse per execution.
///
/// The cache is confined to its connection's queue, so it needs no locking of its own. It also has
/// no `deinit`: it borrows its owner's library table by pointer, and that allocation is released by
/// ``SQLiteHandle`` right after it calls ``finalizeAll()``.
final class SQLiteStatementCache {
  private let library: UnsafePointer<SQLiteLibrary>
  private let connection: OpaquePointer
  private let capacity: Int

  /// Statements that are prepared but not currently lent to a cursor, keyed by their SQL.
  private var idle: [String: OpaquePointer] = [:]

  init(library: UnsafePointer<SQLiteLibrary>, connection: OpaquePointer, capacity: Int) {
    self.library = library
    self.connection = connection
    self.capacity = max(0, capacity)
  }

  /// Prepares a statement the cache does not own, for a caller that will finalize it itself.
  func prepare(_ sql: String) throws -> OpaquePointer {
    try prepare(sql, flags: 0)
  }

  /// Lends the statement for `sql`, preparing one when the cache has none to give.
  ///
  /// A lent statement leaves the cache entirely, so two cursors over the same SQL each get their
  /// own statement rather than trampling one another.
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

  /// Takes a lent statement back, or finalizes it when the cache has no room for it.
  func checkIn(_ statement: OpaquePointer, sql: String) {
    _ = library.pointee.reset(statement)
    _ = library.pointee.clear_bindings(statement)
    guard idle.count < capacity, idle[sql] == nil else {
      _ = library.pointee.finalize(statement)
      return
    }
    idle[sql] = statement
  }

  /// Finalizes every statement the cache holds.
  ///
  /// Statements currently lent to a cursor are not reachable from here, but a cursor is
  /// nonescapable and so cannot outlive the transaction that owns this connection.
  func finalizeAll() {
    for statement in idle.values {
      _ = library.pointee.finalize(statement)
    }
    idle.removeAll()
  }
}
