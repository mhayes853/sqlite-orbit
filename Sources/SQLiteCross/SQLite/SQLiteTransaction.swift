import StructuredQueries

/// Prepares a statement, binds it, and lends it to a cursor.
@_lifetime(immortal)
func makeCursor(
  _ query: QueryFragment,
  connection: OpaquePointer,
  library: UnsafePointer<SQLiteLibrary>,
  statements: SQLiteStatementCache
) throws -> SQLiteRowCursor {
  let (sql, bindings) = prepareQuery(query)
  let statement = try statements.checkOut(sql)
  do {
    for (offset, binding) in bindings.enumerated() {
      try bind(binding, to: statement, at: Int32(offset + 1), library: library)
    }
  } catch {
    // The statement never reached a cursor, so nothing else will give it back.
    statements.checkIn(statement, sql: sql)
    throw error
  }
  return SQLiteRowCursor(
    library: library,
    statement: statement,
    connection: connection,
    sql: sql,
    statements: statements
  )
}

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

  @_lifetime(borrow source)
  init(connection source: borrowing SQLiteConnection) {
    self.connection = source.handle
    self.library = source.library
    self.statements = source.statements
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
    try makeCursor(
      statement.query,
      connection: connection,
      library: library,
      statements: statements
    )
  }
}

/// A write transaction lent by a native SQLite driver.
public struct SQLiteWriteTransaction: DatabaseWriteTransaction, ~Copyable, ~Escapable {
  public typealias Row = SQLiteRow
  public typealias RowCursor = SQLiteRowCursor

  let connection: OpaquePointer
  let library: UnsafePointer<SQLiteLibrary>
  let statements: SQLiteStatementCache

  @_lifetime(borrow source)
  init(connection source: borrowing SQLiteConnection) {
    self.connection = source.handle
    self.library = source.library
    self.statements = source.statements
  }

  /// The underlying `sqlite3 *`.
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
    try makeCursor(
      statement.query,
      connection: connection,
      library: library,
      statements: statements
    )
  }

  @_lifetime(borrow self)
  public borrowing func executeRowCursor<S: DatabaseWriteStatement>(
    _ statement: S
  ) throws -> SQLiteRowCursor {
    try makeCursor(
      statement.query,
      connection: connection,
      library: library,
      statements: statements
    )
  }

  @discardableResult
  public borrowing func execute<S: DatabaseWriteStatement>(_ statement: S) throws -> Int {
    var cursor = try makeCursor(
      statement.query,
      connection: connection,
      library: library,
      statements: statements
    )
    try cursor.drain()
    return Int(library.pointee.changes(connection))
  }

  /// Runs SQL that the query builder does not model, such as schema changes.
  public borrowing func execute(_ sql: String) throws {
    try executeBatch(sql, connection: connection, library: library)
  }
}

extension SQLiteReadTransaction {
  /// Runs read-only SQL that the query builder does not model.
  public borrowing func execute(_ sql: String) throws {
    try executeBatch(sql, connection: connection, library: library)
  }
}

/// Lends a read transaction for the duration of `body`.
///
/// The transaction is constructed here and handed straight to the closure. Nothing else can be
/// done with it, because a nonescapable value cannot be stored.
func withReadTransaction<Result: ~Copyable>(
  on connection: borrowing SQLiteConnection,
  _ body: (borrowing SQLiteReadTransaction) throws -> Result
) throws -> Result {
  try body(SQLiteReadTransaction(connection: connection))
}

/// Lends a write transaction for the duration of `body`.
func withWriteTransaction<Result: ~Copyable>(
  on connection: borrowing SQLiteConnection,
  _ body: (borrowing SQLiteWriteTransaction) throws -> Result
) throws -> Result {
  try body(SQLiteWriteTransaction(connection: connection))
}

/// Runs `body` inside a deferred transaction and always rolls it back.
///
/// A read still takes a transaction so that every statement it runs sees one consistent snapshot,
/// and rolling back is how that snapshot is released — there is nothing to commit.
func runRead<Result: ~Copyable>(
  on connection: borrowing SQLiteConnection,
  _ body: (borrowing SQLiteReadTransaction) throws -> Result
) throws -> Result {
  try connection.execute("BEGIN DEFERRED TRANSACTION")
  let value: Result
  do {
    value = try withReadTransaction(on: connection, body)
  } catch {
    // The body's failure is the one worth reporting, so a failing rollback does not mask it.
    try? connection.execute("ROLLBACK")
    throw error
  }
  try connection.execute("ROLLBACK")
  return value
}

/// Runs `body` inside an immediate transaction, committing it or rolling it back.
///
/// The transaction is immediate rather than deferred so that a write takes SQLite's write lock up
/// front. A deferred write would only discover a competing writer partway through, after work that
/// then has to be thrown away.
func runWrite<Result: ~Copyable>(
  on connection: borrowing SQLiteConnection,
  _ body: (borrowing SQLiteWriteTransaction) throws -> Result
) throws -> Result {
  try connection.execute("BEGIN IMMEDIATE TRANSACTION")
  let value: Result
  do {
    value = try withWriteTransaction(on: connection, body)
  } catch {
    try? connection.execute("ROLLBACK")
    throw error
  }
  do {
    try connection.execute("COMMIT")
  } catch {
    try? connection.execute("ROLLBACK")
    throw error
  }
  return value
}
