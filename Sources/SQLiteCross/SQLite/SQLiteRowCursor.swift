import StructuredQueries

/// A cursor over the rows a statement produces.
///
/// The cursor holds a statement lent by the connection's cache and gives it back when it goes out
/// of scope. That is only safe because the cursor is nonescapable: it cannot outlive the
/// transaction that created it, so a cached statement can never be lent twice or survive its
/// connection.
public struct SQLiteRowCursor: DatabaseRowCursor, ~Copyable, ~Escapable {
  public typealias Row = SQLiteRow

  let library: UnsafePointer<SQLiteLibrary>

  let statement: OpaquePointer

  let connection: OpaquePointer

  let sql: String

  let statements: SQLiteStatementCache

  var isExhausted = false

  @_lifetime(immortal)
  init(
    library: UnsafePointer<SQLiteLibrary>,
    statement: OpaquePointer,
    connection: OpaquePointer,
    sql: String,
    statements: SQLiteStatementCache
  ) {
    self.library = library
    self.statement = statement
    self.connection = connection
    self.sql = sql
    self.statements = statements
  }

  deinit {
    statements.checkIn(statement, sql: sql)
  }

  @_lifetime(&self)
  public mutating func next() throws -> SQLiteRow? {
    guard !isExhausted else { return nil }
    let code = library.pointee.step(statement)
    switch code {
    case SQLiteResultCode.row.rawValue:
      return SQLiteRow(cursor: self)
    case SQLiteResultCode.done.rawValue:
      isExhausted = true
      return nil
    default:
      isExhausted = true
      throw sqliteError(library.pointee, connection: connection, code: code, sql: sql)
    }
  }

  /// Runs the statement to completion, discarding any rows it produces.
  mutating func drain() throws {
    while !isExhausted {
      let code = library.pointee.step(statement)
      switch code {
      case SQLiteResultCode.row.rawValue:
        continue
      case SQLiteResultCode.done.rawValue:
        isExhausted = true
      default:
        isExhausted = true
        throw sqliteError(library.pointee, connection: connection, code: code, sql: sql)
      }
    }
  }
}

/// One result row, valid only until its cursor advances.
public struct SQLiteRow: DatabaseRow, ~Copyable, ~Escapable {
  @usableFromInline
  let library: UnsafePointer<SQLiteLibrary>

  @usableFromInline
  let statement: OpaquePointer

  @_lifetime(borrow cursor)
  init(cursor: borrowing SQLiteRowCursor) {
    self.library = cursor.library
    self.statement = cursor.statement
  }

  @inlinable
  public mutating func decode<Value: QueryRepresentable>(
    _ type: Value.Type
  ) throws -> Value.QueryOutput {
    var decoder = SQLiteRowDecoder(library: library, statement: statement)
    return try Value(decoder: &decoder).queryOutput
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @inlinable
  public mutating func decode<each Value: QueryRepresentable>(
    _ type: (repeat each Value).Type
  ) throws -> (repeat (each Value).QueryOutput) {
    var decoder = SQLiteRowDecoder(library: library, statement: statement)
    return try decoder.decodeColumns((repeat each Value).self)
  }
}
