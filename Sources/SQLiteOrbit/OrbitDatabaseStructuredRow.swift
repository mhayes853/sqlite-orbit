#if StructuredQueries
  public import StructuredQueriesSQLite

  /// A result row that Structured Queries values can be decoded from.
  ///
  /// Each `decode` reads the next column along rather than re-reading the first, so decoding a row is
  /// a walk from left to right. Reading a column by position through ``OrbitDatabaseRow`` does not
  /// move that walk.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var cursor = try transaction.rowCursor(Reminder.select { ($0.id, $0.title) })
  ///   while var row = try cursor.next() {
  ///     let id = try row.decode(Int.self)
  ///     let title = try row.decode(String.self)
  ///     print(id, title)
  ///   }
  /// }
  /// ```
  public protocol OrbitDatabaseStructuredRow: OrbitDatabaseRow, ~Copyable, ~Escapable {
    /// Decodes the next column of this row as a Structured Queries value.
    ///
    /// - Parameter type: The value to decode.
    /// - Returns: The decoded value.
    /// - Throws: ``OrbitDatabaseColumnDecodingError`` when the column's storage class or contents
    ///   cannot produce `type`.
    @_lifetime(self: copy self)
    mutating func decode<Value: QueryRepresentable>(
      _ type: Value.Type
    ) throws -> Value.QueryOutput

    /// Decodes the next columns of this row as a tuple of Structured Queries values.
    ///
    /// - Parameter type: The tuple of values to decode, one column each.
    /// - Returns: The decoded values.
    /// - Throws: ``OrbitDatabaseColumnDecodingError`` when a column's storage class or contents
    ///   cannot produce its value.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @_lifetime(self: copy self)
    mutating func decode<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> (repeat (each Value).QueryOutput)
  }

  /// A cursor that decodes each raw row into one Structured Queries value.
  ///
  /// This is what ``OrbitDatabaseReadTransaction/fetchCursor(_:cached:)`` returns for a statement
  /// that projects a single value, so it is rarely named directly.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var cursor: OrbitDatabaseQueryCursor = try transaction.fetchCursor(Reminder.all)
  ///   while let reminder = try cursor.next() {
  ///     print(reminder.title)
  ///   }
  /// }
  /// ```
  public struct OrbitDatabaseQueryCursor<Base: OrbitDatabaseRowCursor, Value: QueryRepresentable>:
    OrbitDatabaseCursor, ~Copyable, ~Escapable
  where Base: ~Copyable, Base: ~Escapable, Base.Row: OrbitDatabaseStructuredRow {
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
  /// This is what ``OrbitDatabaseReadTransaction/fetchCursor(_:cached:)`` returns for a statement
  /// that projects several values, so it is rarely named directly.
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
  public struct OrbitDatabaseTupleQueryCursor<
    Base: OrbitDatabaseRowCursor,
    each Value: QueryRepresentable
  >:
    OrbitDatabaseCursor, ~Copyable, ~Escapable
  where Base: ~Copyable, Base: ~Escapable, Base.Row: OrbitDatabaseStructuredRow {
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
#endif
