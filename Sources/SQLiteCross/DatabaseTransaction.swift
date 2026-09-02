public import StructuredQueriesSQLite

/// Controls iteration over the rows returned by a query.
public enum DatabaseRowIteration: Sendable {
  case next
  case stop
}

/// The low-level operations available inside a read transaction.
///
/// Transactions are noncopyable and nonescapable so a driver can safely lend a connection whose
/// lifetime is bounded by a ``DatabaseDriver/read(_:)`` or ``DatabaseDriver/write(_:)`` call.
public protocol DatabaseReadTransaction: ~Copyable, ~Escapable {
  associatedtype Row: ~Copyable, ~Escapable, DatabaseRow
  associatedtype RowCursor: ~Copyable, ~Escapable, DatabaseRowCursor where RowCursor.Row == Row

  /// Creates a raw row cursor over the rows returned by a read query.
  ///
  /// - Parameters:
  ///   - query: A query that has been shown to only read.
  ///   - cached: Whether the driver may reuse a prepared statement it has already compiled for
  ///     this SQL. A cached statement is shared by every cursor over the same SQL on the same
  ///     connection, so only pass `true` when the cursor is fully consumed and discarded before
  ///     any other cursor over that SQL is created.
  @_lifetime(borrow self)
  borrowing func rowCursor(
    _ query: DatabaseQuery<DatabaseReadAccess>,
    cached: Bool
  ) throws -> RowCursor
}

/// The low-level operations available inside a write transaction.
///
/// Write transactions can perform every read operation in addition to executing mutations.
public protocol DatabaseWriteTransaction: DatabaseReadTransaction, ~Copyable, ~Escapable {
  /// Creates a raw row cursor over the rows returned by a write query, such as one with a
  /// `RETURNING` clause.
  ///
  /// - Parameters:
  ///   - query: A query to run.
  ///   - cached: Whether the driver may reuse a prepared statement. See
  ///     ``DatabaseReadTransaction/rowCursor(_:cached:)``.
  @_lifetime(borrow self)
  borrowing func rowCursor(
    _ query: DatabaseQuery<DatabaseWriteAccess>,
    cached: Bool
  ) throws -> RowCursor

  /// Runs a query and returns the number of rows it changed.
  @discardableResult
  borrowing func execute(_ query: DatabaseQuery<DatabaseWriteAccess>) throws -> Int
}

extension DatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a raw row cursor over the rows returned by a `SELECT`-shaped statement.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ statement: some PartialSelectStatement,
    cached: Bool = false
  ) throws -> RowCursor {
    try rowCursor(DatabaseQuery<DatabaseReadAccess>(statement), cached: cached)
  }

  /// Creates a raw row cursor over the rows returned by raw SQL.
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
  @_lifetime(borrow self)
  public borrowing func executeRowCursor(
    _ statement: some Statement,
    cached: Bool = false
  ) throws -> RowCursor {
    try rowCursor(DatabaseQuery<DatabaseWriteAccess>(statement), cached: cached)
  }

  /// Executes a statement and returns the number of rows changed by that statement.
  @discardableResult
  public borrowing func execute(_ statement: some Statement) throws -> Int {
    try execute(DatabaseQuery<DatabaseWriteAccess>(statement))
  }

  /// Executes a statement and lends any returned rows to `body`.
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
