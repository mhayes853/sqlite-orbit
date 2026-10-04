#if StructuredQueries
  public import StructuredQueriesSQLite
#endif

/// A single database result row whose lifetime is limited to the current cursor access.
///
/// A row is a view onto the statement's current position. Advancing the cursor invalidates the row
/// it lent, which is why a row is noncopyable and nonescapable. Read a column by its position, or
/// by its name with ``subscript(column:)``, and convert it to a type of your own with
/// ``subscript(_:as:)`` or ``subscript(column:as:)``.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.rowCursor("SELECT id, title FROM reminders")
///   while var row = try cursor.next() {
///     print(try row[0, as: Int.self], row[column: "title"]?.textValue ?? "")
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

  /// The position of the first column with this name, or `nil` if it is missing.
  ///
  /// Names are compared byte for byte, including case. Drivers may cache this lookup for the
  /// lifetime of a cursor. The default implementation searches from left to right.
  func columnIndex(named name: String) -> Int?

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
  /// Finds the first column whose name matches byte for byte, or returns `nil`.
  public func columnIndex(named name: String) -> Int? {
    for index in 0..<columnCount where columnName(at: index).utf8.elementsEqual(name.utf8) {
      return index
    }
    return nil
  }

  /// The position of a property's first mapped result column, or `nil` if the property is
  /// unmapped or the row has no matching column. Uses the same cached, byte-exact lookup as
  /// ``columnIndex(named:)``.
  ///
  /// ```swift
  /// let index = row.columnIndex(for: \ReminderSummary.title)
  /// ```
  public func columnIndex<Root: OrbitDatabaseRowColumns, Value>(
    for keyPath: KeyPath<Root, Value>
  ) -> Int? {
    guard let name = Root.orbitColumnName(for: keyPath) else { return nil }
    return columnIndex(named: name)
  }

  /// Reads a property's mapped result column using the property's type.
  ///
  /// ``OrbitColumn(_:)`` renames are honored. Unmapped properties and missing result columns
  /// throw ``OrbitDatabaseColumnDecodingError``, including for optional properties. SQL NULL
  /// can decode to `nil`. The SQL projection is checked at runtime.
  ///
  /// ```swift
  /// let title = try row[column: \ReminderSummary.title]
  /// ```
  public subscript<
    Root: OrbitDatabaseRowColumns,
    Value: ConvertibleFromOrbitDatabaseValue
  >(column keyPath: KeyPath<Root, Value>) -> Value {
    get throws {
      guard let name = Root.orbitColumnName(for: keyPath) else {
        throw OrbitDatabaseColumnDecodingError(
          columnIndex: nil,
          columnName: "?",
          reason: "to have a SQL name mapped from \(keyPath)"
        )
      }
      return try self[column: name, as: Value.self]
    }
  }

  /// The value of the first column with a name, or `nil` when the row has no such column.
  ///
  /// Uses ``columnIndex(named:)``, so drivers can reuse a cached column mapping.
  ///
  /// ```swift
  /// let title = row[column: "title"]?.textValue
  /// ```
  ///
  /// - Parameter name: The column's name.
  public subscript(column name: String) -> OrbitDatabaseValue? {
    guard let index = columnIndex(named: name) else { return nil }
    return self[index]
  }

  /// The value of a column, converted to a type.
  ///
  /// Read a column that may be `NULL` as an optional.
  ///
  /// ```swift
  /// let id = try row[0, as: Int.self]
  /// let dueDate = try row[1, as: Date?.self]
  /// ```
  ///
  /// - Parameters:
  ///   - index: The column's zero-based position. A position outside the row stops the process.
  ///   - type: The type to convert the value to.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` naming the column when its value cannot be
  ///   converted.
  public subscript<Value: ConvertibleFromOrbitDatabaseValue>(
    index: Int,
    as type: Value.Type
  ) -> Value {
    get throws {
      do {
        return try Value(orbitDatabaseValue: self[index])
      } catch {
        let reason =
          switch error {
          case let error as OrbitDatabaseValueConversionError where error.value == .null:
            "to not be NULL"
          case let error as OrbitDatabaseValueConversionError:
            "to decode \(error.typeName), but found \(error.value.orbitStorageClassName)"
              + (error.reason.map { " (\($0))" } ?? "")
          default:
            "to decode \(Value.self), but \(error)"
          }
        throw OrbitDatabaseColumnDecodingError(
          columnIndex: index,
          columnName: columnName(at: index),
          reason: reason,
          underlyingError: error
        )
      }
    }
  }

  /// The value of the first column with a name, converted to a type.
  ///
  /// Unlike ``subscript(column:)``, which returns `nil`, this throws when the row has no column
  /// with the name, so a misspelled column is not mistaken for a `NULL` one.
  ///
  /// ```swift
  /// let priority = try row[column: "priority", as: Priority?.self]
  /// ```
  ///
  /// - Parameters:
  ///   - name: The column's name, compared exactly.
  ///   - type: The type to convert the value to.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` naming the column when the row has no column
  ///   with the name, or when its value cannot be converted.
  public subscript<Value: ConvertibleFromOrbitDatabaseValue>(
    column name: String,
    as type: Value.Type
  ) -> Value {
    get throws {
      if let index = columnIndex(named: name) {
        return try self[index, as: Value.self]
      }
      throw OrbitDatabaseColumnDecodingError(
        columnIndex: nil,
        columnName: name,
        reason: "to exist"
      )
    }
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
