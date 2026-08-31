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

  /// Creates a raw row cursor over the rows returned by a query.
  @_lifetime(borrow self)
  borrowing func rowCursor<S: DatabaseReadStatement>(_ statement: S) throws -> RowCursor
}

/// The low-level operations available inside a write transaction.
///
/// Write transactions can perform every read operation in addition to executing mutations.
public protocol DatabaseWriteTransaction: DatabaseReadTransaction, ~Copyable, ~Escapable {
  /// Creates a raw row cursor over rows returned by a write statement, such as a `RETURNING`
  /// clause.
  @_lifetime(borrow self)
  borrowing func executeRowCursor<S: DatabaseWriteStatement>(_ statement: S) throws -> RowCursor

  /// Executes a write statement and returns the number of rows changed by that statement.
  @discardableResult
  borrowing func execute<S: DatabaseWriteStatement>(_ statement: S) throws -> Int
}

extension DatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Executes a write statement and lends any returned rows to `body`.
  public borrowing func execute<S: DatabaseWriteStatement>(
    _ statement: S,
    _ body: (inout Row) throws -> DatabaseRowIteration
  ) throws {
    var cursor = try executeRowCursor(statement)
    while var row = try cursor.next() {
      if try body(&row) == .stop { return }
    }
  }
}
