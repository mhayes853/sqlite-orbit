public import StructuredQueries

/// Whether a database transaction permits reads or writes.
public enum DatabaseTransactionAccessKind: Hashable, Sendable {
  case read
  case write
}

/// Controls iteration over the rows returned by a query.
public enum DatabaseRowIteration: Sendable {
  case next
  case stop
}

/// A single database result row whose lifetime is limited to the query callback.
public protocol DatabaseRow: ~Copyable, ~Escapable {
  /// Decodes a Structured Queries value from this row.
  mutating func decode<Value: QueryRepresentable>(
    _ type: Value.Type
  ) throws -> Value.QueryOutput

  /// Decodes a tuple of Structured Queries values from this row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  mutating func decode<each Value: QueryRepresentable>(
    _ type: (repeat each Value).Type
  ) throws -> (repeat (each Value).QueryOutput)
}

/// The low-level operations available inside a database transaction.
///
/// Transactions are noncopyable and nonescapable so a driver can safely lend a connection whose
/// lifetime is bounded by a ``DatabaseDriver/read(_:)`` or ``DatabaseDriver/write(_:)`` call.
public protocol DatabaseTransaction: ~Copyable, ~Escapable {
  associatedtype Row: ~Copyable, ~Escapable, DatabaseRow

  var accessKind: DatabaseTransactionAccessKind { borrowing get }

  /// Executes a statement and returns the number of rows changed by that statement.
  @discardableResult
  borrowing func execute(_ query: QueryFragment) throws -> Int

  /// Executes a query and lends each result row to `body`.
  borrowing func query(
    _ query: QueryFragment,
    _ body: (inout Row) throws -> DatabaseRowIteration
  ) throws
}
