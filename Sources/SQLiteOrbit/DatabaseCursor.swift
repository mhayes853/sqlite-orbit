public import StructuredQueriesSQLite

/// A single database result row whose lifetime is limited to the current cursor access.
///
/// A row is a view onto the statement's current position, so each `decode` reads the next column
/// along rather than re-reading the first. Advancing the cursor invalidates the row it lent, which
/// is why a row is noncopyable and nonescapable.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.rowCursor(#sql("SELECT id, title FROM reminders", as: Void.self))
///   while var row = try cursor.next() {
///     let id = try row.decode(Int.self)
///     let title = try row.decode(String.self)
///     print(id, title)
///   }
/// }
/// ```
public protocol DatabaseRow: ~Copyable, ~Escapable {
  /// Decodes the next column of this row as a Structured Queries value.
  ///
  /// - Parameter type: The value to decode.
  /// - Returns: The decoded value.
  /// - Throws: ``DatabaseColumnDecodingError`` when the column's storage class or contents cannot
  ///   produce `type`.
  mutating func decode<Value: QueryRepresentable>(
    _ type: Value.Type
  ) throws -> Value.QueryOutput

  /// Decodes the next columns of this row as a tuple of Structured Queries values.
  ///
  /// - Parameter type: The tuple of values to decode, one column each.
  /// - Returns: The decoded values.
  /// - Throws: ``DatabaseColumnDecodingError`` when a column's storage class or contents cannot
  ///   produce its value.
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
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.rowCursor(#sql("SELECT title FROM reminders", as: Void.self))
///   try cursor.forEach { row in
///     print(try row.decode(String.self))
///   }
/// }
/// ```
public protocol DatabaseRowCursor: ~Copyable, ~Escapable {
  /// The row this cursor lends.
  associatedtype Row: ~Copyable, ~Escapable, DatabaseRow

  /// Advances the cursor and lends the next row, or returns `nil` when exhausted.
  ///
  /// - Returns: The next row, valid only until the cursor advances again.
  /// - Throws: A ``SQLiteError`` when the statement fails while producing the row.
  @_lifetime(&self)
  mutating func next() throws -> Row?

  /// Calls `body` for every remaining row in the cursor.
  ///
  /// - Parameter body: Receives each row in turn.
  /// - Throws: Whatever `body` throws, or a ``SQLiteError`` when the statement fails.
  mutating func forEach(_ body: (inout Row) throws -> Void) throws
}

extension DatabaseRowCursor where Self: ~Copyable, Self: ~Escapable {
  /// Calls `body` for every remaining row in the cursor.
  ///
  /// - Parameter body: Receives each row in turn.
  /// - Throws: Whatever `body` throws, or a ``SQLiteError`` when the statement fails.
  @inlinable
  public mutating func forEach(_ body: (inout Row) throws -> Void) throws {
    while var row = try next() {
      try body(&row)
    }
  }
}

/// A cursor over decoded values returned by a database statement.
///
/// Rows are decoded and produced one at a time, so a query whose results do not fit in memory can
/// still be walked. The lazy adapters below — ``map(_:)``, ``filter(_:)``, ``prefix(_:)`` and the
/// rest — compose without materializing anything, and the terminal operations such as
/// ``collect()`` and ``count()`` consume the cursor.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.fetchCursor(Reminder.all)
///     .filter { !$0.isCompleted }
///     .map(\.title)
///   return try cursor.collect()
/// }
/// ```
public protocol DatabaseCursor<Element>: ~Copyable, ~Escapable {
  /// The value this cursor produces for each row.
  associatedtype Element

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
  ///
  /// - Returns: The next value, or `nil` once every row has been produced.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row that
  ///   cannot produce ``Element``.
  mutating func next() throws -> Element?

  /// Calls `body` for every remaining value in the cursor.
  ///
  /// - Parameter body: Receives each value in turn.
  /// - Throws: Whatever `body` throws, or whatever ``next()`` throws.
  mutating func forEach(_ body: (inout Element) throws -> Void) throws
}

extension DatabaseCursor where Self: ~Copyable, Self: ~Escapable {
  /// Calls `body` for every remaining value in the cursor.
  ///
  /// - Parameter body: Receives each value in turn.
  /// - Throws: Whatever `body` throws, or whatever ``next()`` throws.
  @inlinable
  public mutating func forEach(_ body: (inout Element) throws -> Void) throws {
    while var value = try next() {
      try body(&value)
    }
  }
}

/// A cursor that decodes each raw row into one Structured Queries value.
///
/// This is what ``DatabaseReadTransaction/fetchCursor(_:cached:)`` returns for a statement that
/// projects a single value, so it is rarely named directly.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor: DatabaseQueryCursor = try transaction.fetchCursor(Reminder.all)
///   while let reminder = try cursor.next() {
///     print(reminder.title)
///   }
/// }
/// ```
public struct DatabaseQueryCursor<Base: DatabaseRowCursor, Value: QueryRepresentable>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
  public typealias Element = Value.QueryOutput

  @usableFromInline
  internal var base: Base

  @_lifetime(copy base)
  @usableFromInline
  internal init(base: consuming Base) {
    self.base = base
  }

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
  @inlinable
  public mutating func next() throws -> Value.QueryOutput? {
    guard var row = try base.next() else { return nil }
    return try row.decode(Value.self)
  }
}

/// A cursor that decodes each raw row into a tuple of Structured Queries values.
///
/// This is what ``DatabaseReadTransaction/fetchCursor(_:cached:)`` returns for a statement that
/// projects several values, so it is rarely named directly.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.fetchCursor(Reminder.select { ($0.id, $0.title) })
///   while let (id, title) = try cursor.next() {
///     print(id, title)
///   }
/// }
/// ```
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct DatabaseTupleQueryCursor<Base: DatabaseRowCursor, each Value: QueryRepresentable>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
  public typealias Element = (repeat (each Value).QueryOutput)

  @usableFromInline
  internal var base: Base

  @_lifetime(copy base)
  @usableFromInline
  internal init(base: consuming Base) {
    self.base = base
  }

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
  @inlinable
  public mutating func next() throws -> (repeat (each Value).QueryOutput)? {
    guard var row = try base.next() else { return nil }
    return try row.decode((repeat each Value).self)
  }
}

/// A cursor that lazily transforms each value from a base cursor.
///
/// Created by ``DatabaseCursor/map(_:)``.
///
/// ```swift
/// var titles = try transaction.fetchCursor(Reminder.all).map(\.title)
/// ```
public struct DatabaseMapCursor<Base: DatabaseCursor, Output>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
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

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
  @inlinable
  public mutating func next() throws -> Output? {
    guard let value = try base.next() else { return nil }
    return try transform(value)
  }
}

/// A cursor that lazily filters values from a base cursor.
///
/// Created by ``DatabaseCursor/filter(_:)``.
///
/// ```swift
/// var pending = try transaction.fetchCursor(Reminder.all).filter { !$0.isCompleted }
/// ```
public struct DatabaseFilterCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
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

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
  @inlinable
  public mutating func next() throws -> Base.Element? {
    while let value = try base.next() {
      if try predicate(value) {
        return value
      }
    }
    return nil
  }
}

/// A cursor that lazily transforms and drops `nil` values from a base cursor.
///
/// Created by ``DatabaseCursor/compactMap(_:)``.
///
/// ```swift
/// var ids = try transaction.fetchCursor(Reminder.all).compactMap { Int($0.title) }
/// ```
public struct DatabaseCompactMapCursor<Base: DatabaseCursor, Output>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
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

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
  @inlinable
  public mutating func next() throws -> Output? {
    while let value = try base.next() {
      if let output = try transform(value) {
        return output
      }
    }
    return nil
  }
}

/// A cursor that lazily skips a fixed number of values from a base cursor.
///
/// Created by ``DatabaseCursor/dropFirst(_:)``.
///
/// ```swift
/// var afterTheFirstTen = try transaction.fetchCursor(Reminder.all).dropFirst(10)
/// ```
public struct DatabaseDropFirstCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
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

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
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
}

/// A cursor that lazily skips values while a predicate succeeds.
///
/// Created by ``DatabaseCursor/drop(while:)``.
///
/// ```swift
/// var fromTheFirstPending = try transaction.fetchCursor(Reminder.all)
///   .drop(while: \.isCompleted)
/// ```
public struct DatabaseDropWhileCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
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

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
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
}

/// A cursor that lazily limits iteration to a fixed number of values.
///
/// Created by ``DatabaseCursor/prefix(_:)``.
///
/// ```swift
/// var firstTen = try transaction.fetchCursor(Reminder.all).prefix(10)
/// ```
public struct DatabasePrefixCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
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

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
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
}

/// A cursor that lazily limits iteration while a predicate succeeds.
///
/// Created by ``DatabaseCursor/prefix(while:)``.
///
/// ```swift
/// var leadingCompleted = try transaction.fetchCursor(Reminder.all)
///   .prefix(while: \.isCompleted)
/// ```
public struct DatabasePrefixWhileCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
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

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
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
}

/// A cursor that pairs each value with its zero-based offset.
///
/// Created by ``DatabaseCursor/enumerated()``.
///
/// ```swift
/// var numbered = try transaction.fetchCursor(Reminder.all).enumerated()
/// while let (offset, reminder) = try numbered.next() {
///   print(offset, reminder.title)
/// }
/// ```
public struct DatabaseEnumeratedCursor<Base: DatabaseCursor>:
  DatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The value this cursor produces for each row.
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

  /// Advances the cursor and returns the next value, or `nil` when exhausted.
  @inlinable
  public mutating func next() throws -> (offset: Int, element: Base.Element)? {
    guard let value = try base.next() else { return nil }
    defer { offset += 1 }
    return (offset: offset, element: value)
  }
}

extension DatabaseCursor where Self: ~Copyable, Self: ~Escapable {
  /// Lazily transforms each value in this cursor.
  ///
  /// Nothing is read from the database until the returned cursor is advanced.
  ///
  /// ```swift
  /// var titles = try transaction.fetchCursor(Reminder.all).map(\.title)
  /// let uppercased = try titles.map { $0.uppercased() }.collect()
  /// ```
  ///
  /// - Parameter transform: Produces the value the returned cursor yields for each value of this
  ///   one.
  /// - Returns: A cursor over the transformed values.
  @_lifetime(copy self)
  @inlinable
  public consuming func map<Output>(
    _ transform: @escaping (Element) throws -> Output
  ) -> DatabaseMapCursor<Self, Output> {
    DatabaseMapCursor(base: consume self, transform: transform)
  }

  /// Lazily filters values in this cursor.
  ///
  /// ```swift
  /// var pending = try transaction.fetchCursor(Reminder.all).filter { !$0.isCompleted }
  /// ```
  ///
  /// - Parameter predicate: Answers whether a value is kept.
  /// - Returns: A cursor over the values `predicate` accepted.
  @_lifetime(copy self)
  @inlinable
  public consuming func filter(
    _ predicate: @escaping (Element) throws -> Bool
  ) -> DatabaseFilterCursor<Self> {
    DatabaseFilterCursor(base: consume self, predicate: predicate)
  }

  /// Lazily transforms values in this cursor and drops `nil` results.
  ///
  /// ```swift
  /// var dueDates = try transaction.fetchCursor(Reminder.all).compactMap(\.dueDate)
  /// ```
  ///
  /// - Parameter transform: Produces a value to yield, or `nil` to skip this one.
  /// - Returns: A cursor over the non-`nil` transformed values.
  @_lifetime(copy self)
  @inlinable
  public consuming func compactMap<Output>(
    _ transform: @escaping (Element) throws -> Output?
  ) -> DatabaseCompactMapCursor<Self, Output> {
    DatabaseCompactMapCursor(base: consume self, transform: transform)
  }

  /// Lazily drops the first `count` values from this cursor.
  ///
  /// - Parameter count: How many values to skip. Must not be negative.
  /// - Returns: A cursor over the values after the first `count`.
  @_lifetime(copy self)
  @inlinable
  public consuming func dropFirst(_ count: Int) -> DatabaseDropFirstCursor<Self> {
    DatabaseDropFirstCursor(base: consume self, count: count)
  }

  /// Lazily drops values while the predicate succeeds.
  ///
  /// Once a value fails `predicate`, that value and every value after it are yielded, whether or
  /// not they would have passed.
  ///
  /// ```swift
  /// var fromTheFirstPending = try transaction.fetchCursor(Reminder.all)
  ///   .drop(while: \.isCompleted)
  /// ```
  ///
  /// - Parameter predicate: Answers whether a leading value is still being dropped.
  /// - Returns: A cursor beginning at the first value `predicate` rejected.
  @_lifetime(copy self)
  @inlinable
  public consuming func drop(
    while predicate: @escaping (Element) throws -> Bool
  ) -> DatabaseDropWhileCursor<Self> {
    DatabaseDropWhileCursor(base: consume self, predicate: predicate)
  }

  /// Lazily limits this cursor to at most `maxLength` values.
  ///
  /// - Parameter maxLength: The greatest number of values to yield. Must not be negative.
  /// - Returns: A cursor over at most `maxLength` values.
  @_lifetime(copy self)
  @inlinable
  public consuming func prefix(_ maxLength: Int) -> DatabasePrefixCursor<Self> {
    DatabasePrefixCursor(base: consume self, count: maxLength)
  }

  /// Lazily limits this cursor while the predicate succeeds.
  ///
  /// The cursor ends at the first value `predicate` rejects, which is not yielded.
  ///
  /// - Parameter predicate: Answers whether iteration continues.
  /// - Returns: A cursor over the leading values `predicate` accepted.
  @_lifetime(copy self)
  @inlinable
  public consuming func prefix(
    while predicate: @escaping (Element) throws -> Bool
  ) -> DatabasePrefixWhileCursor<Self> {
    DatabasePrefixWhileCursor(base: consume self, predicate: predicate)
  }

  /// Lazily pairs each value with its zero-based offset.
  ///
  /// ```swift
  /// var numbered = try transaction.fetchCursor(Reminder.all).enumerated()
  /// while let (offset, reminder) = try numbered.next() {
  ///   print(offset, reminder.title)
  /// }
  /// ```
  ///
  /// - Returns: A cursor over `(offset:element:)` pairs.
  @_lifetime(copy self)
  @inlinable
  public consuming func enumerated() -> DatabaseEnumeratedCursor<Self> {
    DatabaseEnumeratedCursor(base: consume self)
  }

  /// Eagerly collects the remaining values into an array.
  ///
  /// ```swift
  /// let titles = try await database.read { transaction in
  ///   var cursor = try transaction.fetchCursor(Reminder.select(\.title))
  ///   return try cursor.collect()
  /// }
  /// ```
  ///
  /// - Returns: Every remaining value, in the order the statement produced it.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func collect() throws -> [Element] {
    try collect(as: [Element].self)
  }

  /// Eagerly collects the remaining values into a range-replaceable collection.
  ///
  /// ```swift
  /// let titles = try cursor.collect(as: ContiguousArray<String>.self)
  /// ```
  ///
  /// - Parameter type: The collection to build.
  /// - Returns: Every remaining value, in the order the statement produced it.
  /// - Throws: Whatever ``next()`` throws.
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
  ///
  /// ```swift
  /// let distinctTitles = try cursor.collect(as: Set<String>.self)
  /// ```
  ///
  /// - Parameter type: The collection to build.
  /// - Returns: Every remaining value, with duplicates merged by the collection.
  /// - Throws: Whatever ``next()`` throws.
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
  ///
  /// - Returns: `true` when the statement produced no further row.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func isEmpty() throws -> Bool {
    try next() == nil
  }

  /// Returns the first remaining value, or `nil` if the cursor is empty.
  ///
  /// Only one row is read, so this is the cheap way to ask for a single result.
  ///
  /// - Returns: The next value, or `nil`.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func first() throws -> Element? {
    try next()
  }

  /// Returns the first remaining value matching a predicate, or `nil` if no value matches.
  ///
  /// Iteration stops at the first match, so the rest of the statement is never stepped.
  ///
  /// - Parameter predicate: Answers whether a value is the one being looked for.
  /// - Returns: The first matching value, or `nil`.
  /// - Throws: Whatever `predicate` or ``next()`` throws.
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
  ///
  /// - Parameter predicate: Answers whether a value counts as a match.
  /// - Returns: `true` as soon as a value matches.
  /// - Throws: Whatever `predicate` or ``next()`` throws.
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
  ///
  /// - Parameter predicate: Answers whether a value is acceptable.
  /// - Returns: `false` as soon as a value fails, and `true` for an empty cursor.
  /// - Throws: Whatever `predicate` or ``next()`` throws.
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
  ///
  /// Every row is stepped and decoded. `SELECT count(*)` is the cheaper question to ask the
  /// database when only the count is wanted; see ``DatabaseReadTransaction/fetchCount(_:)``.
  ///
  /// - Returns: How many values remained.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func count() throws -> Int {
    try count { _ in true }
  }

  /// Returns the number of remaining values matching a predicate.
  ///
  /// - Parameter predicate: Answers whether a value is counted.
  /// - Returns: How many remaining values matched.
  /// - Throws: Whatever `predicate` or ``next()`` throws.
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
  ///
  /// ```swift
  /// let totalTitleLength = try cursor.reduce(0) { $0 + $1.title.count }
  /// ```
  ///
  /// - Parameters:
  ///   - initialResult: The value the reduction starts from.
  ///   - nextPartialResult: Combines the running result with the next value.
  /// - Returns: The final result.
  /// - Throws: Whatever `nextPartialResult` or ``next()`` throws.
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
  ///
  /// ```swift
  /// let byID = try cursor.reduce(into: [Int: Reminder]()) { $0[$1.id] = $1 }
  /// ```
  ///
  /// - Parameters:
  ///   - initialResult: The value the reduction starts from.
  ///   - updateAccumulatingResult: Folds the next value into the running result.
  /// - Returns: The final result.
  /// - Throws: Whatever `updateAccumulatingResult` or ``next()`` throws.
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
  ///
  /// - Returns: The smallest remaining value, or `nil`.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func min() throws -> Element? where Element: Comparable {
    try min(by: <)
  }

  /// Returns the maximum remaining value, or `nil` if the cursor is empty.
  ///
  /// - Returns: The largest remaining value, or `nil`.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func max() throws -> Element? where Element: Comparable {
    try max(by: <)
  }

  /// Returns the minimum remaining value according to a comparison predicate.
  ///
  /// - Parameter areInIncreasingOrder: Answers whether its first argument sorts before its second.
  /// - Returns: The smallest remaining value, or `nil` when the cursor is empty.
  /// - Throws: Whatever `areInIncreasingOrder` or ``next()`` throws.
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
  ///
  /// - Parameter areInIncreasingOrder: Answers whether its first argument sorts before its second.
  /// - Returns: The largest remaining value, or `nil` when the cursor is empty.
  /// - Throws: Whatever `areInIncreasingOrder` or ``next()`` throws.
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
  ///
  /// One pass answers both, which is the point: a cursor cannot be walked twice.
  ///
  /// ```swift
  /// var cursor = try transaction.fetchCursor(Reminder.select(\.id))
  /// let bounds = try cursor.minMax()
  /// ```
  ///
  /// - Returns: The smallest and largest remaining values, or `nil`.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func minMax() throws -> (min: Element, max: Element)?
  where Element: Comparable {
    try minMax(by: <)
  }

  /// Returns the minimum and maximum remaining values according to a comparison predicate.
  ///
  /// - Parameter areInIncreasingOrder: Answers whether its first argument sorts before its second.
  /// - Returns: The smallest and largest remaining values, or `nil` when the cursor is empty.
  /// - Throws: Whatever `areInIncreasingOrder` or ``next()`` throws.
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

  /// Returns the `k` largest remaining values, ordered from largest to smallest.
  ///
  /// Fewer than `k` values are returned when the cursor holds fewer than `k` values. Only `k`
  /// values are ever held at once, so this scales to a result set that would not fit in memory.
  ///
  /// ```swift
  /// var cursor = try transaction.fetchCursor(Reminder.select(\.id))
  /// let highestIDs = try cursor.topK(3)
  /// ```
  ///
  /// - Parameter k: How many values to keep. Must not be negative.
  /// - Returns: The `k` largest values, largest first.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func topK(_ k: Int) throws -> [Element] where Element: Comparable {
    try topK(k, by: <)
  }

  /// Returns the `k` largest remaining values according to a comparison predicate, ordered from
  /// largest to smallest.
  ///
  /// Fewer than `k` values are returned when the cursor holds fewer than `k` values.
  ///
  /// - Parameters:
  ///   - k: How many values to keep. Must not be negative.
  ///   - areInIncreasingOrder: Answers whether its first argument sorts before its second.
  /// - Returns: The `k` largest values, largest first.
  /// - Throws: Whatever `areInIncreasingOrder` or ``next()`` throws.
  @inlinable
  public consuming func topK(
    _ k: Int,
    by areInIncreasingOrder: (Element, Element) throws -> Bool
  ) throws -> [Element] {
    precondition(k >= 0, "Cannot take a negative number of top elements from a cursor")
    guard k > 0 else { return [] }

    // A heap rooted at the smallest kept value: the root is what a larger newcomer displaces.
    var heap = DatabaseCursorHeap<Element>(capacity: k)
    try forEach { value in
      try heap.insert(value, by: areInIncreasingOrder)
    }
    return try heap.drain(by: areInIncreasingOrder)
  }

  /// Returns the `k` smallest and the `k` largest remaining values.
  ///
  /// The `min` values are ordered from smallest to largest and the `max` values from largest to
  /// smallest. Both groups draw from the same values, so they overlap when the cursor holds fewer
  /// than `2 * k` values.
  ///
  /// ```swift
  /// var cursor = try transaction.fetchCursor(Reminder.select(\.id))
  /// let (lowest, highest) = try cursor.minMaxK(3)
  /// ```
  ///
  /// - Parameter k: How many values to keep at each end. Must not be negative.
  /// - Returns: The `k` smallest and the `k` largest values.
  /// - Throws: Whatever ``next()`` throws.
  @inlinable
  public consuming func minMaxK(
    _ k: Int
  ) throws -> (min: [Element], max: [Element]) where Element: Comparable {
    try minMaxK(k, by: <)
  }

  /// Returns the `k` smallest and the `k` largest remaining values according to a comparison
  /// predicate.
  ///
  /// The `min` values are ordered from smallest to largest and the `max` values from largest to
  /// smallest. Both groups draw from the same values, so they overlap when the cursor holds fewer
  /// than `2 * k` values.
  ///
  /// - Parameters:
  ///   - k: How many values to keep at each end. Must not be negative.
  ///   - areInIncreasingOrder: Answers whether its first argument sorts before its second.
  /// - Returns: The `k` smallest and the `k` largest values.
  /// - Throws: Whatever `areInIncreasingOrder` or ``next()`` throws.
  @inlinable
  public consuming func minMaxK(
    _ k: Int,
    by areInIncreasingOrder: (Element, Element) throws -> Bool
  ) throws -> (min: [Element], max: [Element]) {
    precondition(k >= 0, "Cannot take a negative number of extreme elements from a cursor")
    guard k > 0 else { return (min: [], max: []) }

    // The smallest values are kept by a heap rooted at the largest of them, so its ordering is the
    // reverse of the one the largest values use.
    var minimums = DatabaseCursorHeap<Element>(capacity: k)
    var maximums = DatabaseCursorHeap<Element>(capacity: k)
    try forEach { value in
      try minimums.insert(value, by: { try areInIncreasingOrder($1, $0) })
      try maximums.insert(value, by: areInIncreasingOrder)
    }
    return (
      min: try minimums.drain(by: { try areInIncreasingOrder($1, $0) }),
      max: try maximums.drain(by: areInIncreasingOrder)
    )
  }
}
