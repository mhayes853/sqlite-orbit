import StructuredQueries

/// A cursor over the rows a statement produces.
///
/// The cursor holds a statement lent by the connection's cache and gives it back when it goes out
/// of scope. That is only safe because the cursor is nonescapable: it cannot outlive the
/// transaction that created it, so a cached statement can never be lent twice or survive its
/// connection.
public struct SQLiteRowCursor: DatabaseRowCursor, ~Copyable, ~Escapable {
  public typealias Row = SQLiteRow

  @usableFromInline
  let library: UnsafePointer<SQLiteLibrary>

  @usableFromInline
  let statement: OpaquePointer

  @usableFromInline
  let connection: OpaquePointer

  @usableFromInline
  let sql: String

  let statements: SQLiteStatementCache

  /// Whether the statement came from the cache, and so has to go back rather than be finalized.
  let isCached: Bool

  @usableFromInline
  var isExhausted = false

  /// Prepares and binds `query`, holding its statement for as long as the cursor lives.
  ///
  /// A cached statement is lent by the connection's cache and returned when the cursor goes out of
  /// scope. An uncached one belongs to the cursor alone and is finalized there, which is what lets
  /// two cursors over the same SQL be open at once.
  @_lifetime(borrow statements)
  init(
    _ query: QueryFragment,
    cached: Bool,
    connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    statements: borrowing SQLiteStatementCache
  ) throws {
    let (sql, bindings) = prepareQuery(query)
    let statement = cached ? try statements.checkOut(sql) : try statements.prepare(sql)
    do {
      for (offset, binding) in bindings.enumerated() {
        try bind(binding, to: statement, at: Int32(offset + 1), library: library)
      }
    } catch {
      // The statement never reached a cursor, so nothing else will give it back.
      if cached {
        statements.checkIn(statement, sql: sql)
      } else {
        _ = library.pointee.finalize(statement)
      }
      throw error
    }
    self.library = library
    self.statement = statement
    self.connection = connection
    self.sql = sql
    self.statements = copy statements
    self.isCached = cached
  }

  deinit {
    if isCached {
      statements.checkIn(statement, sql: sql)
    } else {
      _ = library.pointee.finalize(statement)
    }
  }

  @inlinable
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
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
    }
  }
}

/// One result row, valid only until its cursor advances.
public struct SQLiteRow: DatabaseRow, ~Copyable, ~Escapable {
  @usableFromInline
  var decoder: SQLiteRowDecoder

  @usableFromInline
  @_lifetime(borrow cursor)
  init(cursor: borrowing SQLiteRowCursor) {
    self.decoder = SQLiteRowDecoder(library: cursor.library, statement: cursor.statement)
  }

  @inlinable
  public mutating func decode<Value: QueryRepresentable>(
    _ type: Value.Type
  ) throws -> Value.QueryOutput {
    do {
      return try Value(decoder: &decoder).queryOutput
    } catch let error as QueryDecodingError {
      throw decoder.describe(error)
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @inlinable
  public mutating func decode<each Value: QueryRepresentable>(
    _ type: (repeat each Value).Type
  ) throws -> (repeat (each Value).QueryOutput) {
    do {
      return try decoder.decodeColumns((repeat each Value).self)
    } catch let error as QueryDecodingError {
      throw decoder.describe(error)
    }
  }
}
