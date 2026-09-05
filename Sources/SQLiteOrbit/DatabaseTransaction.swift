public import StructuredQueriesSQLite

/// Controls iteration over the rows returned by a query.
///
/// Returned from the body of ``DatabaseWriteTransaction/execute(_:_:)`` to say whether the next
/// row should be read.
///
/// ```swift
/// try await database.write { transaction in
///   try transaction.execute(Reminder.insert { Reminder(id: 1, title: "Get milk") }
///     .returning(\.id)) { row in
///     print(try row.decode(Int.self))
///     return .stop
///   }
/// }
/// ```
public enum DatabaseRowIteration: Sendable {
  /// Read the next row.
  case next
  /// Stop reading, leaving any remaining rows unread.
  case stop
}

/// The low-level operations available inside a read transaction.
///
/// Transactions are noncopyable and nonescapable so a database can safely lend a connection whose
/// lifetime is bounded by a ``SQLiteDatabaseReader/read(_:)`` or ``SQLiteDatabaseWriter/write(_:)``
/// call. The `fetch` family in `DatabaseTransaction+StructuredQueries` is built on the one
/// requirement below, so a conformance only has to know how to lend a cursor.
///
/// ```swift
/// let pending = try await database.read { transaction in
///   try transaction.fetchAll(Reminder.where { !$0.isCompleted })
/// }
/// ```
public protocol DatabaseReadTransaction: ~Copyable, ~Escapable {
  /// The row this transaction's cursors lend.
  associatedtype Row: ~Copyable, ~Escapable, DatabaseRow

  /// The cursor this transaction lends.
  associatedtype RowCursor: ~Copyable, ~Escapable, DatabaseRowCursor where RowCursor.Row == Row

  /// Creates a raw row cursor over the rows returned by a read query.
  ///
  /// - Parameters:
  ///   - query: A query that has been shown to only read.
  ///   - cached: Whether the driver may reuse a prepared statement it has already compiled for
  ///     this SQL. A cached statement is shared by every cursor over the same SQL on the same
  ///     connection, so only pass `true` when the cursor is fully consumed and discarded before
  ///     any other cursor over that SQL is created.
  /// - Returns: A cursor over the statement's rows, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  borrowing func rowCursor(
    _ query: DatabaseQuery<DatabaseReadAccess>,
    cached: Bool
  ) throws -> RowCursor
}

/// The low-level operations available inside a write transaction.
///
/// Write transactions can perform every read operation in addition to executing mutations.
///
/// ```swift
/// try await database.write { transaction in
///   try transaction.execute(Reminder.insert { Reminder(id: 1, title: "Get milk") })
///   try transaction.execute(Reminder.where { $0.id == 1 }.update { $0.isCompleted = true })
/// }
/// ```
public protocol DatabaseWriteTransaction: DatabaseReadTransaction, ~Copyable, ~Escapable {
  /// Creates a raw row cursor over the rows returned by a write query, such as one with a
  /// `RETURNING` clause.
  ///
  /// - Parameters:
  ///   - query: A query to run.
  ///   - cached: Whether the driver may reuse a prepared statement. See
  ///     ``DatabaseReadTransaction/rowCursor(_:cached:)``.
  /// - Returns: A cursor over the statement's rows, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  borrowing func rowCursor(
    _ query: DatabaseQuery<DatabaseWriteAccess>,
    cached: Bool
  ) throws -> RowCursor

  /// Runs a query and returns the number of rows it changed.
  ///
  /// - Parameter query: The query to run. Any rows it returns are discarded.
  /// - Returns: The number of rows the statement inserted, updated, or deleted.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  @discardableResult
  borrowing func execute(_ query: DatabaseQuery<DatabaseWriteAccess>) throws -> Int
}

extension DatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a raw row cursor over the rows returned by a `SELECT`-shaped statement.
  ///
  /// Rows are lent undecoded, which is the escape hatch for reading columns the query builder
  /// does not describe. ``DatabaseReadTransaction/fetchCursor(_:cached:)`` is the typed
  /// equivalent.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var cursor = try transaction.rowCursor(Reminder.select(\.title))
  ///   try cursor.forEach { print(try $0.decode(String.self)) }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - statement: A statement that only reads.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the statement's rows.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ statement: some PartialSelectStatement,
    cached: Bool = false
  ) throws -> RowCursor {
    try rowCursor(DatabaseQuery<DatabaseReadAccess>(statement), cached: cached)
  }

  /// Creates a raw row cursor over the rows returned by raw SQL.
  ///
  /// The capability of raw SQL cannot be read off its type, so the caller is stating that it
  /// reads.
  ///
  /// ```swift
  /// var cursor = try transaction.rowCursor(#sql("PRAGMA table_info(reminders)", as: Void.self))
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The SQL to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the statement's rows.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor<QueryValue>(
    _ statement: SQLQueryExpression<QueryValue>,
    cached: Bool = false
  ) throws -> RowCursor {
    try rowCursor(DatabaseQuery<DatabaseReadAccess>(statement), cached: cached)
  }
}

extension DatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a raw row cursor over the rows returned by a write statement.
  ///
  /// ```swift
  /// var cursor = try transaction.executeRowCursor(
  ///   Reminder.insert { Reminder(id: 1, title: "Get milk") }.returning(\.id)
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the rows the statement returned.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func executeRowCursor(
    _ statement: some Statement,
    cached: Bool = false
  ) throws -> RowCursor {
    try rowCursor(DatabaseQuery<DatabaseWriteAccess>(statement), cached: cached)
  }

  /// Executes a statement and returns the number of rows changed by that statement.
  ///
  /// ```swift
  /// let deleted = try transaction.execute(Reminder.where(\.isCompleted).delete())
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: The number of rows the statement inserted, updated, or deleted.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  @discardableResult
  public borrowing func execute(_ statement: some Statement) throws -> Int {
    try execute(DatabaseQuery<DatabaseWriteAccess>(statement))
  }

  /// Executes a statement and lends any returned rows to `body`.
  ///
  /// Rows are lent one at a time and `body` decides whether to read the next, so a `RETURNING`
  /// clause can be consumed without collecting it.
  ///
  /// ```swift
  /// try transaction.execute(
  ///   Reminder.insert { Reminder(id: 1, title: "Get milk") }.returning(\.id)
  /// ) { row in
  ///   print(try row.decode(Int.self))
  ///   return .next
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to run.
  ///   - body: Receives each returned row and says whether to read the next.
  /// - Throws: Whatever `body` throws, or a ``SQLiteError`` when the statement fails.
  public borrowing func execute(
    _ statement: some Statement,
    _ body: (inout Row) throws -> DatabaseRowIteration
  ) throws {
    var cursor = try executeRowCursor(statement)
    while var row = try cursor.next() {
      if try body(&row) == .stop { return }
    }
  }
}
