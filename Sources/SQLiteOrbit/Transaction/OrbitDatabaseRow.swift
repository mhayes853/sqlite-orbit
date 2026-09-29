#if StructuredQueries
  public import StructuredQueriesSQLite
#endif

/// A single database result row whose lifetime is limited to the current cursor access.
///
/// A row is a view onto the statement's current position. Advancing the cursor invalidates the row
/// it lent, which is why a row is noncopyable and nonescapable. Read a column by its position, or
/// by its name with ``subscript(column:)``.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.rowCursor("SELECT id, title FROM reminders")
///   while var row = try cursor.next() {
///     print(row[0].integerValue ?? 0, row[column: "title"]?.textValue ?? "")
///   }
/// }
/// ```
public protocol OrbitDatabaseRow: ~Copyable, ~Escapable {
  /// How many columns the row has.
  var columnCount: Int { get }

  /// The name of a column, as SQLite reports it: the `AS` name when the query gives one.
  ///
  /// - Parameter index: The column's zero-based position, which must be less than
  ///   ``columnCount``.
  /// - Returns: The column's name.
  func columnName(at index: Int) -> String

  /// The value of a column.
  ///
  /// Reading a column by position does not move a decoder's position through the row, so it can
  /// be mixed with decoding.
  ///
  /// - Parameter index: The column's zero-based position. A position outside the row stops the
  ///   process.
  subscript(index: Int) -> OrbitDatabaseValue { get }

  /// The value of the first column with a name, or `nil` when the row has no such column.
  ///
  /// Names are compared exactly, and the columns are searched from left to right.
  ///
  /// - Parameter name: The column's name.
  subscript(column name: String) -> OrbitDatabaseValue? { get }
}

extension OrbitDatabaseRow where Self: ~Copyable, Self: ~Escapable {
  /// The value of the first column with a name, or `nil` when the row has no such column.
  ///
  /// Names are compared exactly, and the columns are searched from left to right, so read by
  /// position where a row has many columns and is read often.
  ///
  /// ```swift
  /// let title = row[column: "title"]?.textValue
  /// ```
  ///
  /// - Parameter name: The column's name.
  public subscript(column name: String) -> OrbitDatabaseValue? {
    for index in 0..<columnCount where columnName(at: index) == name {
      return self[index]
    }
    return nil
  }
}

// MARK: - Structured Queries

#if StructuredQueries
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
#endif
