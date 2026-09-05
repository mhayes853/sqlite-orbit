import StructuredQueries

/// A read transaction lent by a native SQLite driver.
///
/// The transaction is a view onto a connection rather than an owner of one. It is noncopyable and
/// nonescapable, so the connection it borrows cannot be captured, stored, or outlived.
///
/// ```swift
/// let titles = try await database.read { (transaction: borrowing SQLiteReadTransaction) in
///   try transaction.fetchAll(Reminder.select(\.title))
/// }
/// ```
public struct SQLiteReadTransaction: OrbitDatabaseReadTransaction, ~Copyable, ~Escapable {
  /// The row this transaction's cursors lend.
  public typealias Row = SQLiteRow

  /// The cursor this transaction lends.
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

  /// Creates a cursor over the rows a read query returns.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseReadAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try cursor(for: query.fragment, cached: cached)
  }

  /// Runs SQL that the query builder does not model, such as schema changes.
  ///
  /// Several statements may be given at once, separated by semicolons, and any rows they produce
  /// are discarded.
  ///
  /// ```swift
  /// try transaction.execute("PRAGMA optimize")
  /// ```
  ///
  /// - Parameter sql: One or more statements.
  /// - Throws: A ``SQLiteError`` naming the SQL that failed.
  public borrowing func execute(_ sql: String) throws {
    try SQLiteHandle.execute(sql, on: connection, library: library)
  }

  @_lifetime(borrow self)
  borrowing func cursor(for query: QueryFragment, cached: Bool) throws -> SQLiteRowCursor {
    try SQLiteRowCursor(
      query,
      cached: cached,
      connection: connection,
      library: library,
      statements: statements
    )
  }
}

/// A write transaction lent by a native SQLite driver.
///
/// A write transaction is a read transaction that may also mutate, so it wraps one rather than
/// repeating it.
///
/// ```swift
/// try await database.write { (transaction: borrowing SQLiteWriteTransaction) in
///   try transaction.execute(Reminder.insert { Reminder(id: 1, title: "Get milk") })
/// }
/// ```
public struct SQLiteWriteTransaction: OrbitDatabaseWriteTransaction, ~Copyable, ~Escapable {
  /// The row this transaction's cursors lend.
  public typealias Row = SQLiteRow

  /// The cursor this transaction lends.
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

  /// Creates a cursor over the rows a read query returns.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseReadAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try base.cursor(for: query.fragment, cached: cached)
  }

  /// Creates a cursor over the rows a write query returns, such as one with a `RETURNING` clause.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseWriteAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try base.cursor(for: query.fragment, cached: cached)
  }

  /// Runs a query to completion and reports how many rows it changed.
  ///
  /// - Parameter query: The query to run. Any rows it returns are stepped past and discarded.
  /// - Returns: The number of rows inserted, updated, or deleted, and `0` for a query that builds
  ///   no SQL at all.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  @discardableResult
  public borrowing func execute(_ query: OrbitDatabaseQuery<OrbitDatabaseWriteAccess>) throws -> Int
  {
    // A statement that builds no SQL changes nothing. Running the empty-query stand-in would leave
    // `changes` reporting whatever the previous statement changed.
    guard !query.fragment.isEmpty else { return 0 }
    var cursor = try base.cursor(for: query.fragment, cached: false)
    try cursor.forEach { _ in }
    return Int(base.library.pointee.changes(base.connection))
  }

  /// Runs SQL that the query builder does not model, such as schema changes.
  ///
  /// Several statements may be given at once, separated by semicolons, and any rows they produce
  /// are discarded.
  ///
  /// ```swift
  /// try transaction.execute(
  ///   "CREATE TABLE reminders (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
  /// )
  /// ```
  ///
  /// - Parameter sql: One or more statements.
  /// - Throws: A ``SQLiteError`` naming the SQL that failed.
  public borrowing func execute(_ sql: String) throws {
    try base.execute(sql)
  }
}
