public import StructuredQueries

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

/// A cursor that lazily transforms each value from a base cursor.
public struct DatabaseMapCursor<Base: DatabaseCursor, Output>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = Output

  private var base: Base
  private let transform: (Base.Element) throws -> Output

  @_lifetime(copy base)
  init(
    base: consuming Base,
    transform: @escaping (Base.Element) throws -> Output
  ) {
    self.base = base
    self.transform = transform
  }

  public mutating func next() throws -> Output? {
    guard let value = try base.next() else { return nil }
    return try transform(value)
  }

  public mutating func forEach(_ body: (inout Output) throws -> Void) throws {
    try base.forEach { value in
      var output = try transform(value)
      try body(&output)
    }
  }
}

/// A cursor that lazily filters values from a base cursor.
public struct DatabaseFilterCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = Base.Element

  private var base: Base
  private let predicate: (Base.Element) throws -> Bool

  @_lifetime(copy base)
  init(
    base: consuming Base,
    predicate: @escaping (Base.Element) throws -> Bool
  ) {
    self.base = base
    self.predicate = predicate
  }

  public mutating func next() throws -> Base.Element? {
    while let value = try base.next() {
      if try predicate(value) {
        return value
      }
    }
    return nil
  }

  public mutating func forEach(_ body: (inout Base.Element) throws -> Void) throws {
    try base.forEach { value in
      if try predicate(value) {
        try body(&value)
      }
    }
  }
}

/// A cursor that lazily transforms and drops `nil` values from a base cursor.
public struct DatabaseCompactMapCursor<Base: DatabaseCursor, Output>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = Output

  private var base: Base
  private let transform: (Base.Element) throws -> Output?

  @_lifetime(copy base)
  init(
    base: consuming Base,
    transform: @escaping (Base.Element) throws -> Output?
  ) {
    self.base = base
    self.transform = transform
  }

  public mutating func next() throws -> Output? {
    while let value = try base.next() {
      if let output = try transform(value) {
        return output
      }
    }
    return nil
  }

  public mutating func forEach(_ body: (inout Output) throws -> Void) throws {
    try base.forEach { value in
      if var output = try transform(value) {
        try body(&output)
      }
    }
  }
}

extension DatabaseCursor where Self: ~Copyable, Self: ~Escapable {
  /// Lazily transforms each value in this cursor.
  @_lifetime(copy self)
  public consuming func map<Output>(
    _ transform: @escaping (Element) throws -> Output
  ) -> DatabaseMapCursor<Self, Output> {
    DatabaseMapCursor(base: consume self, transform: transform)
  }

  /// Lazily filters values in this cursor.
  @_lifetime(copy self)
  public consuming func filter(
    _ predicate: @escaping (Element) throws -> Bool
  ) -> DatabaseFilterCursor<Self> {
    DatabaseFilterCursor(base: consume self, predicate: predicate)
  }

  /// Lazily transforms values in this cursor and drops `nil` results.
  @_lifetime(copy self)
  public consuming func compactMap<Output>(
    _ transform: @escaping (Element) throws -> Output?
  ) -> DatabaseCompactMapCursor<Self, Output> {
    DatabaseCompactMapCursor(base: consume self, transform: transform)
  }
}
