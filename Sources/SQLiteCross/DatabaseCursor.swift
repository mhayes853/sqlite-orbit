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
  @inlinable
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

  @usableFromInline
  internal var base: Base

  @_lifetime(copy base)
  @usableFromInline
  internal init(base: consuming Base) {
    self.base = base
  }

  @inlinable
  public mutating func next() throws -> Value.QueryOutput? {
    guard var row = try base.next() else { return nil }
    return try row.decode(Value.self)
  }

  @inlinable
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

  @usableFromInline
  internal var base: Base

  @_lifetime(copy base)
  @usableFromInline
  internal init(base: consuming Base) {
    self.base = base
  }

  @inlinable
  public mutating func next() throws -> (repeat (each Value).QueryOutput)? {
    guard var row = try base.next() else { return nil }
    return try row.decode((repeat each Value).self)
  }

  @inlinable
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

  @usableFromInline
  internal var base: Base
  @usableFromInline
  internal let transform: (Base.Element) throws -> Output

  @_lifetime(copy base)
  @usableFromInline
  internal init(
    base: consuming Base,
    transform: @escaping (Base.Element) throws -> Output
  ) {
    self.base = base
    self.transform = transform
  }

  @inlinable
  public mutating func next() throws -> Output? {
    guard let value = try base.next() else { return nil }
    return try transform(value)
  }

  @inlinable
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

  @usableFromInline
  internal var base: Base
  @usableFromInline
  internal let predicate: (Base.Element) throws -> Bool

  @_lifetime(copy base)
  @usableFromInline
  internal init(
    base: consuming Base,
    predicate: @escaping (Base.Element) throws -> Bool
  ) {
    self.base = base
    self.predicate = predicate
  }

  @inlinable
  public mutating func next() throws -> Base.Element? {
    while let value = try base.next() {
      if try predicate(value) {
        return value
      }
    }
    return nil
  }

  @inlinable
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

  @usableFromInline
  internal var base: Base
  @usableFromInline
  internal let transform: (Base.Element) throws -> Output?

  @_lifetime(copy base)
  @usableFromInline
  internal init(
    base: consuming Base,
    transform: @escaping (Base.Element) throws -> Output?
  ) {
    self.base = base
    self.transform = transform
  }

  @inlinable
  public mutating func next() throws -> Output? {
    while let value = try base.next() {
      if let output = try transform(value) {
        return output
      }
    }
    return nil
  }

  @inlinable
  public mutating func forEach(_ body: (inout Output) throws -> Void) throws {
    try base.forEach { value in
      if var output = try transform(value) {
        try body(&output)
      }
    }
  }
}

/// A cursor that lazily skips a fixed number of values from a base cursor.
public struct DatabaseDropFirstCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = Base.Element

  @usableFromInline
  internal var base: Base
  @usableFromInline
  internal var remaining: Int

  @_lifetime(copy base)
  @usableFromInline
  internal init(base: consuming Base, count: Int) {
    self.base = base
    precondition(count >= 0, "Cannot drop a negative number of elements from a cursor")
    self.remaining = count
  }

  @inlinable
  public mutating func next() throws -> Base.Element? {
    while remaining > 0 {
      guard try base.next() != nil else {
        remaining = 0
        return nil
      }
      remaining -= 1
    }
    return try base.next()
  }

  @inlinable
  public mutating func forEach(_ body: (inout Base.Element) throws -> Void) throws {
    var remaining = remaining
    try base.forEach { value in
      if remaining > 0 {
        remaining -= 1
      } else {
        try body(&value)
      }
    }
    self.remaining = remaining
  }
}

/// A cursor that lazily skips values while a predicate succeeds.
public struct DatabaseDropWhileCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = Base.Element

  @usableFromInline
  internal var base: Base
  @usableFromInline
  internal var isDropping = true
  @usableFromInline
  internal let predicate: (Base.Element) throws -> Bool

  @_lifetime(copy base)
  @usableFromInline
  internal init(
    base: consuming Base,
    predicate: @escaping (Base.Element) throws -> Bool
  ) {
    self.base = base
    self.predicate = predicate
  }

  @inlinable
  public mutating func next() throws -> Base.Element? {
    while isDropping {
      guard let value = try base.next() else {
        isDropping = false
        return nil
      }
      if try predicate(value) {
        continue
      }
      isDropping = false
      return value
    }
    return try base.next()
  }

  @inlinable
  public mutating func forEach(_ body: (inout Base.Element) throws -> Void) throws {
    var isDropping = isDropping
    try base.forEach { value in
      if isDropping {
        if try predicate(value) {
          return
        }
        isDropping = false
      }
      try body(&value)
    }
    self.isDropping = isDropping
  }
}

/// A cursor that lazily limits iteration to a fixed number of values.
public struct DatabasePrefixCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = Base.Element

  @usableFromInline
  internal var base: Base
  @usableFromInline
  internal var remaining: Int

  @_lifetime(copy base)
  @usableFromInline
  internal init(base: consuming Base, count: Int) {
    self.base = base
    precondition(count >= 0, "Cannot take a prefix of negative length from a cursor")
    self.remaining = count
  }

  @inlinable
  public mutating func next() throws -> Base.Element? {
    guard remaining > 0 else { return nil }
    guard let value = try base.next() else {
      remaining = 0
      return nil
    }
    remaining -= 1
    return value
  }

  @inlinable
  public mutating func forEach(_ body: (inout Base.Element) throws -> Void) throws {
    while var value = try next() {
      try body(&value)
    }
  }
}

/// A cursor that lazily limits iteration while a predicate succeeds.
public struct DatabasePrefixWhileCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = Base.Element

  @usableFromInline
  internal var base: Base
  @usableFromInline
  internal var isFinished = false
  @usableFromInline
  internal let predicate: (Base.Element) throws -> Bool

  @_lifetime(copy base)
  @usableFromInline
  internal init(
    base: consuming Base,
    predicate: @escaping (Base.Element) throws -> Bool
  ) {
    self.base = base
    self.predicate = predicate
  }

  @inlinable
  public mutating func next() throws -> Base.Element? {
    guard !isFinished, let value = try base.next() else {
      isFinished = true
      return nil
    }
    guard try predicate(value) else {
      isFinished = true
      return nil
    }
    return value
  }

  @inlinable
  public mutating func forEach(_ body: (inout Base.Element) throws -> Void) throws {
    while var value = try next() {
      try body(&value)
    }
  }
}

/// A cursor that pairs each value with its zero-based offset.
public struct DatabaseEnumeratedCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  public typealias Element = (offset: Int, element: Base.Element)

  @usableFromInline
  internal var base: Base
  @usableFromInline
  internal var offset = 0

  @_lifetime(copy base)
  @usableFromInline
  internal init(base: consuming Base) {
    self.base = base
  }

  @inlinable
  public mutating func next() throws -> (offset: Int, element: Base.Element)? {
    guard let value = try base.next() else { return nil }
    defer { offset += 1 }
    return (offset: offset, element: value)
  }

  @inlinable
  public mutating func forEach(
    _ body: (inout (offset: Int, element: Base.Element)) throws -> Void
  ) throws {
    var offset = offset
    try base.forEach { value in
      var enumerated = (offset: offset, element: value)
      offset += 1
      try body(&enumerated)
    }
    self.offset = offset
  }
}

extension DatabaseCursor where Self: ~Copyable, Self: ~Escapable {
  /// Lazily transforms each value in this cursor.
  @_lifetime(copy self)
  @inlinable
  public consuming func map<Output>(
    _ transform: @escaping (Element) throws -> Output
  ) -> DatabaseMapCursor<Self, Output> {
    DatabaseMapCursor(base: consume self, transform: transform)
  }

  /// Lazily filters values in this cursor.
  @_lifetime(copy self)
  @inlinable
  public consuming func filter(
    _ predicate: @escaping (Element) throws -> Bool
  ) -> DatabaseFilterCursor<Self> {
    DatabaseFilterCursor(base: consume self, predicate: predicate)
  }

  /// Lazily transforms values in this cursor and drops `nil` results.
  @_lifetime(copy self)
  @inlinable
  public consuming func compactMap<Output>(
    _ transform: @escaping (Element) throws -> Output?
  ) -> DatabaseCompactMapCursor<Self, Output> {
    DatabaseCompactMapCursor(base: consume self, transform: transform)
  }

  /// Lazily drops the first `count` values from this cursor.
  @_lifetime(copy self)
  @inlinable
  public consuming func dropFirst(_ count: Int) -> DatabaseDropFirstCursor<Self> {
    DatabaseDropFirstCursor(base: consume self, count: count)
  }

  /// Lazily drops values while the predicate succeeds.
  @_lifetime(copy self)
  @inlinable
  public consuming func drop(
    while predicate: @escaping (Element) throws -> Bool
  ) -> DatabaseDropWhileCursor<Self> {
    DatabaseDropWhileCursor(base: consume self, predicate: predicate)
  }

  /// Lazily limits this cursor to at most `maxLength` values.
  @_lifetime(copy self)
  @inlinable
  public consuming func prefix(_ maxLength: Int) -> DatabasePrefixCursor<Self> {
    DatabasePrefixCursor(base: consume self, count: maxLength)
  }

  /// Lazily limits this cursor while the predicate succeeds.
  @_lifetime(copy self)
  @inlinable
  public consuming func prefix(
    while predicate: @escaping (Element) throws -> Bool
  ) -> DatabasePrefixWhileCursor<Self> {
    DatabasePrefixWhileCursor(base: consume self, predicate: predicate)
  }

  /// Lazily pairs each value with its zero-based offset.
  @_lifetime(copy self)
  @inlinable
  public consuming func enumerated() -> DatabaseEnumeratedCursor<Self> {
    DatabaseEnumeratedCursor(base: consume self)
  }

  /// Eagerly collects the remaining values into an array.
  @inlinable
  public consuming func collect() throws -> [Element] {
    try collect(as: [Element].self)
  }

  /// Eagerly collects the remaining values into a range-replaceable collection.
  @inlinable
  public consuming func collect<C: RangeReplaceableCollection>(
    as type: C.Type
  ) throws -> C where C.Element == Element {
    var collection = C()
    try forEach { value in
      collection.append(value)
    }
    return collection
  }

  /// Eagerly collects the remaining values into a set-algebra collection.
  @inlinable
  public consuming func collect<C: SetAlgebra>(
    as type: C.Type
  ) throws -> C where C.Element == Element {
    var collection = C()
    try forEach { value in
      collection.insert(value)
    }
    return collection
  }

  /// Returns whether the cursor has no remaining values.
  @inlinable
  public consuming func isEmpty() throws -> Bool {
    try next() == nil
  }

  /// Returns the first remaining value, or `nil` if the cursor is empty.
  @inlinable
  public consuming func first() throws -> Element? {
    try next()
  }

  /// Returns the first remaining value matching a predicate, or `nil` if no value matches.
  @inlinable
  public consuming func first(
    where predicate: (Element) throws -> Bool
  ) throws -> Element? {
    while let value = try next() {
      if try predicate(value) {
        return value
      }
    }
    return nil
  }

  /// Returns whether any remaining value matches a predicate.
  @inlinable
  public consuming func contains(
    where predicate: (Element) throws -> Bool
  ) throws -> Bool {
    while let value = try next() {
      if try predicate(value) {
        return true
      }
    }
    return false
  }

  /// Returns whether every remaining value matches a predicate.
  @inlinable
  public consuming func allSatisfy(
    _ predicate: (Element) throws -> Bool
  ) throws -> Bool {
    while let value = try next() {
      if try !predicate(value) {
        return false
      }
    }
    return true
  }

  /// Returns the number of remaining values.
  @inlinable
  public consuming func count() throws -> Int {
    try count { _ in true }
  }

  /// Returns the number of remaining values matching a predicate.
  @inlinable
  public consuming func count(
    where predicate: (Element) throws -> Bool
  ) throws -> Int {
    var result = 0
    try forEach { value in
      if try predicate(value) {
        result += 1
      }
    }
    return result
  }

  /// Reduces the remaining values into a single result.
  @inlinable
  public consuming func reduce<Result>(
    _ initialResult: Result,
    _ nextPartialResult: (Result, Element) throws -> Result
  ) throws -> Result {
    var result = initialResult
    try forEach { value in
      result = try nextPartialResult(result, value)
    }
    return result
  }

  /// Reduces the remaining values into a mutable result.
  @inlinable
  public consuming func reduce<Result>(
    into initialResult: Result,
    _ updateAccumulatingResult: (inout Result, Element) throws -> Void
  ) throws -> Result {
    var result = initialResult
    try forEach { value in
      try updateAccumulatingResult(&result, value)
    }
    return result
  }

  /// Returns the minimum remaining value, or `nil` if the cursor is empty.
  @inlinable
  public consuming func min() throws -> Element? where Element: Comparable {
    try min(by: <)
  }

  /// Returns the maximum remaining value, or `nil` if the cursor is empty.
  @inlinable
  public consuming func max() throws -> Element? where Element: Comparable {
    try max(by: <)
  }

  /// Returns the minimum remaining value according to a comparison predicate.
  @inlinable
  public consuming func min(
    by areInIncreasingOrder: (Element, Element) throws -> Bool
  ) throws -> Element? {
    var result: Element?
    try forEach { value in
      guard let current = result else {
        result = value
        return
      }
      if try areInIncreasingOrder(value, current) {
        result = value
      }
    }
    return result
  }

  /// Returns the maximum remaining value according to a comparison predicate.
  @inlinable
  public consuming func max(
    by areInIncreasingOrder: (Element, Element) throws -> Bool
  ) throws -> Element? {
    var result: Element?
    try forEach { value in
      guard let current = result else {
        result = value
        return
      }
      if try areInIncreasingOrder(current, value) {
        result = value
      }
    }
    return result
  }

  /// Returns the minimum and maximum remaining values, or `nil` if the cursor is empty.
  @inlinable
  public consuming func minMax() throws -> (min: Element, max: Element)?
  where Element: Comparable {
    try minMax(by: <)
  }

  /// Returns the minimum and maximum remaining values according to a comparison predicate.
  @inlinable
  public consuming func minMax(
    by areInIncreasingOrder: (Element, Element) throws -> Bool
  ) throws -> (min: Element, max: Element)? {
    var result: (min: Element, max: Element)?
    try forEach { value in
      guard let current = result else {
        result = (min: value, max: value)
        return
      }

      var minimum = current.min
      var maximum = current.max
      if try areInIncreasingOrder(value, minimum) {
        minimum = value
      }
      if try areInIncreasingOrder(maximum, value) {
        maximum = value
      }
      result = (min: minimum, max: maximum)
    }
    return result
  }
}
