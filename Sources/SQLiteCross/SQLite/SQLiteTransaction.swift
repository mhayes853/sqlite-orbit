import StructuredQueries

/// A read transaction lent by a native SQLite driver.
///
/// The transaction is a view onto a connection rather than an owner of one. It is noncopyable and
/// nonescapable, so the connection it borrows cannot be captured, stored, or outlived.
public struct SQLiteReadTransaction: DatabaseReadTransaction, ~Copyable, ~Escapable {
  public typealias Row = SQLiteRow
  public typealias RowCursor = SQLiteRowCursor

  let connection: OpaquePointer
  let library: UnsafePointer<SQLiteLibrary>
  let statements: SQLiteStatementCache

  @_lifetime(borrow handle)
  init(handle: borrowing SQLiteHandle) {
    self.connection = handle.pointer
    self.library = handle.library
    self.statements = handle.statements
  }

  /// The underlying `sqlite3 *`.
  ///
  /// This is the escape hatch for work the package does not model. It is only valid for the
  /// duration of the access that lent this transaction.
  public var sqliteConnection: OpaquePointer {
    connection
  }

  /// The SQLite build this connection runs against, so raw work uses the same one.
  public var sqlite: SQLiteLibrary {
    library.pointee
  }

  @_lifetime(borrow self)
  public borrowing func rowCursor<S: DatabaseReadStatement>(
    _ statement: S
  ) throws -> SQLiteRowCursor {
    try cursor(for: statement.query)
  }

  /// Runs SQL that the query builder does not model, such as schema changes.
  public borrowing func execute(_ sql: String) throws {
    try SQLiteHandle.execute(sql, on: connection, library: library)
  }

  @_lifetime(borrow self)
  borrowing func cursor(for query: QueryFragment) throws -> SQLiteRowCursor {
    try SQLiteRowCursor(query, connection: connection, library: library, statements: statements)
  }
}

/// A write transaction lent by a native SQLite driver.
///
/// A write transaction is a read transaction that may also mutate, so it wraps one rather than
/// repeating it.
public struct SQLiteWriteTransaction: DatabaseWriteTransaction, ~Copyable, ~Escapable {
  public typealias Row = SQLiteRow
  public typealias RowCursor = SQLiteRowCursor

  let base: SQLiteReadTransaction

  @_lifetime(borrow handle)
  init(handle: borrowing SQLiteHandle) {
    self.base = SQLiteReadTransaction(handle: handle)
  }

  /// The underlying `sqlite3 *`.
  public var sqliteConnection: OpaquePointer {
    base.connection
  }

  /// The SQLite build this connection runs against, so raw work uses the same one.
  public var sqlite: SQLiteLibrary {
    base.sqlite
  }

  @_lifetime(borrow self)
  public borrowing func rowCursor<S: DatabaseReadStatement>(
    _ statement: S
  ) throws -> SQLiteRowCursor {
    try base.cursor(for: statement.query)
  }

  @_lifetime(borrow self)
  public borrowing func executeRowCursor<S: DatabaseWriteStatement>(
    _ statement: S
  ) throws -> SQLiteRowCursor {
    try base.cursor(for: statement.query)
  }

  @discardableResult
  public borrowing func execute<S: DatabaseWriteStatement>(_ statement: S) throws -> Int {
    var cursor = try base.cursor(for: statement.query)
    try cursor.forEach { _ in }
    return Int(base.library.pointee.changes(base.connection))
  }

  /// Runs SQL that the query builder does not model, such as schema changes.
  public borrowing func execute(_ sql: String) throws {
    try base.execute(sql)
  }
}
