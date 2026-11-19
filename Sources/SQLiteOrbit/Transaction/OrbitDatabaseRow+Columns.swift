// MARK: - Nested Rows

extension OrbitDatabaseRow where Self: ~Copyable, Self: ~Escapable {
  /// Reads a nested row from the columns whose names start with a prefix.
  ///
  /// The nested value sees only those columns, under their names with the prefix removed, so a row
  /// type written for one table can be read out of a join that aliases that table's columns:
  ///
  /// ```swift
  /// let pairs = try transaction.fetchAll(
  ///   """
  ///   SELECT r.id, r.title, l.id AS list_id, l.name AS list_name
  ///   FROM reminders r JOIN lists l ON l.id = r.list_id
  ///   """
  /// ) { row in
  ///   (try row[columns: "", as: Reminder.self], try row[columns: "list_", as: RemindersList.self])
  /// }
  /// ```
  ///
  /// Prefixes match UTF-8 bytes exactly, including case. An empty prefix reads the nested value
  /// from this row unchanged. A column decoding failure is reported against this row's column, not
  /// the nested one.
  ///
  /// - Parameters:
  ///   - prefix: The prefix shared by the nested value's column names.
  ///   - type: The nested value to read.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` when no column has the prefix, or when the
  ///   nested value fails to read one of its columns.
  public subscript<Value: ConvertibleFromOrbitDatabaseRow>(
    columns prefix: String,
    as type: Value.Type
  ) -> Value {
    get throws {
      guard !prefix.isEmpty else { return try Value(orbitDatabaseRow: self) }
      return try OrbitDatabaseColumnScope(self, prefix: prefix).decode(Value.self)
    }
  }

  /// Reads an optional nested row from the columns whose names start with a prefix, producing
  /// `nil` when every one of those columns is `NULL`.
  ///
  /// This is the shape of a `LEFT JOIN` that matched nothing:
  ///
  /// ```swift
  /// let list = try row[columns: "list_", as: RemindersList?.self]
  /// ```
  ///
  /// A matched row whose columns are all `NULL` also reads as `nil`. An empty prefix considers
  /// every column of this row.
  ///
  /// - Parameters:
  ///   - prefix: The prefix shared by the nested value's column names.
  ///   - type: The optional nested value to read.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` when no column has the prefix, or when the
  ///   nested value fails to read one of its columns.
  public subscript<Value: ConvertibleFromOrbitDatabaseRow>(
    columns prefix: String,
    as type: Value?.Type
  ) -> Value? {
    get throws {
      guard !prefix.isEmpty else {
        for index in 0..<columnCount where self[index] != .null {
          return try Value(orbitDatabaseRow: self)
        }
        return nil
      }
      let scope = try OrbitDatabaseColumnScope(self, prefix: prefix)
      return scope.isAllNull ? nil : try scope.decode(Value.self)
    }
  }
}

// MARK: - Scope

/// The columns of a row that share a name prefix, copied out under their unprefixed names.
///
/// Swift cannot yet store a borrow of a generic noncopyable row, so a scope owns its values rather
/// than viewing the row it came from.
struct OrbitDatabaseColumnScope: OrbitDatabaseRow {
  private let prefix: String
  private var columns: [(name: String, value: OrbitDatabaseValue, baseIndex: Int)] = []
  private(set) var isAllNull = true

  init<Base: OrbitDatabaseRow & ~Copyable & ~Escapable>(
    _ base: borrowing Base,
    prefix: String
  ) throws {
    self.prefix = prefix
    let prefixBytes = prefix.utf8
    for index in 0..<base.columnCount {
      let name = base.columnName(at: index)
      guard name.utf8.starts(with: prefixBytes) else { continue }
      let value = base[index]
      if value != .null { isAllNull = false }
      columns.append(
        (String(decoding: name.utf8.dropFirst(prefixBytes.count), as: UTF8.self), value, index)
      )
    }
    guard !columns.isEmpty else {
      throw OrbitDatabaseColumnDecodingError(
        columnIndex: nil,
        columnName: prefix,
        reason: "to prefix at least one column"
      )
    }
  }

  var columnCount: Int { columns.count }

  func columnName(at index: Int) -> String { columns[index].name }

  subscript(index: Int) -> OrbitDatabaseValue { columns[index].value }

  /// Reads a value from this scope, reporting a column failure against the row it came from.
  func decode<Value: ConvertibleFromOrbitDatabaseRow>(_ type: Value.Type) throws -> Value {
    do {
      return try Value(orbitDatabaseRow: self)
    } catch let error as OrbitDatabaseColumnDecodingError {
      if let index = error.columnIndex {
        guard columns.indices.contains(index) else { throw error }
        throw OrbitDatabaseColumnDecodingError(
          columnIndex: columns[index].baseIndex,
          columnName: prefix + columns[index].name,
          reason: error.reason,
          sql: error.sql,
          underlyingError: error.underlyingError
        )
      }
      throw OrbitDatabaseColumnDecodingError(
        // "?" stands for a property with no mapped column, which no prefix makes more precise.
        columnIndex: nil,
        columnName: error.columnName == "?" ? "?" : prefix + error.columnName,
        reason: error.reason,
        sql: error.sql,
        underlyingError: error.underlyingError
      )
    }
  }
}
