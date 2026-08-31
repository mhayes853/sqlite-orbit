public import StructuredQueries

/// Controls iteration over the rows returned by a query.
public enum DatabaseRowIteration: Sendable {
  case next
  case stop
}

/// A single database result row whose lifetime is limited to the current cursor access.
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

/// A cursor over raw rows returned by a database statement.
///
/// Cursors are tied to the transaction that created them. They must be consumed before the
/// transaction access operation returns, and the current row must not be retained after advancing
/// the cursor.
public protocol DatabaseRowCursor: ~Copyable, ~Escapable {
  associatedtype Row: ~Copyable, ~Escapable, DatabaseRow

  /// Advances the cursor and lends the next row, or returns `nil` when exhausted.
  @_lifetime(&self)
  mutating func next() throws -> Row?

  /// Calls `body` for every remaining row in the cursor.
  mutating func forEach(_ body: (inout Row) throws -> Void) throws
}

extension DatabaseRowCursor where Self: ~Copyable, Self: ~Escapable {
  public mutating func forEach(_ body: (inout Row) throws -> Void) throws {
    while var row = try next() {
      try body(&row)
    }
  }
}

/// A cursor over decoded values returned by a database statement.
public protocol DatabaseCursor<Element>: ~Copyable, ~Escapable {
  associatedtype Element

  mutating func next() throws -> Element?
  mutating func forEach(_ body: (inout Element) throws -> Void) throws
}

/// A cursor that decodes each raw row into one Structured Queries value.
public struct DatabaseQueryCursor<Base: DatabaseRowCursor, Value: QueryRepresentable>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = Value.QueryOutput

  private var base: Base

  @_lifetime(copy base)
  init(base: consuming Base) {
    self.base = base
  }

  public mutating func next() throws -> Value.QueryOutput? {
    guard var row = try base.next() else { return nil }
    return try row.decode(Value.self)
  }

  public mutating func forEach(
    _ body: (inout Value.QueryOutput) throws -> Void
  ) throws {
    try base.forEach { row in
      var value = try row.decode(Value.self)
      try body(&value)
    }
  }
}

/// A cursor that decodes each raw row into a tuple of Structured Queries values.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct DatabaseTupleQueryCursor<Base: DatabaseRowCursor, each Value: QueryRepresentable>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = (repeat (each Value).QueryOutput)

  private var base: Base

  @_lifetime(copy base)
  init(base: consuming Base) {
    self.base = base
  }

  public mutating func next() throws -> (repeat (each Value).QueryOutput)? {
    guard var row = try base.next() else { return nil }
    return try row.decode((repeat each Value).self)
  }

  public mutating func forEach(
    _ body: (inout (repeat (each Value).QueryOutput)) throws -> Void
  ) throws {
    try base.forEach { row in
      var value = try row.decode((repeat each Value).self)
      try body(&value)
    }
  }
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
