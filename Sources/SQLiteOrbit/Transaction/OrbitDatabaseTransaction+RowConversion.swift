extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Returns a value initialized from each row SQL that only reads returns.
  ///
  /// A type that is ``ConvertibleFromOrbitDatabaseValue`` reads the first column of each row, and
  /// any other ``ConvertibleFromOrbitDatabaseRow`` type reads the row through its own initializer.
  /// A value type that declares its own row initializer uses that instead of the first column.
  ///
  /// ```swift
  /// let titles = try transaction.fetchAll("SELECT title FROM reminders", as: String.self)
  /// let summaries = try transaction.fetchAll(
  ///   "SELECT id, title FROM reminders",
  ///   as: ReminderSummary.self
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run, which must only read.
  ///   - type: The type to initialize from each row. Make a value type optional to read `NULL`.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever the type's initializer throws, such as
  ///   ``OrbitDatabaseColumnDecodingError``, or a ``SQLiteError`` when the statement fails or may
  ///   write.
  public borrowing func fetchAll<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    as type: Value.Type
  ) throws -> [Value] {
    try withOrbitCursor(try rowCursor(sql, cached: true)) { try $0.collect(as: Value.self) }
  }

  /// Returns a value initialized from the first row SQL that only reads returns, or `nil` when it
  /// returns none.
  ///
  /// Only the first row is read.
  ///
  /// ```swift
  /// let count = try transaction.fetchOne("SELECT count(*) FROM reminders", as: Int.self)
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run, which must only read.
  ///   - type: The type to initialize from the row.
  /// - Returns: The value, or `nil` when the SQL returned no rows.
  /// - Throws: Whatever the type's initializer throws, such as
  ///   ``OrbitDatabaseColumnDecodingError``, or a ``SQLiteError`` when the statement fails or may
  ///   write.
  public borrowing func fetchOne<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    as type: Value.Type
  ) throws -> Value? {
    try withOrbitCursor(try rowCursor(sql, cached: true)) { try $0.first(as: Value.self) }
  }

  /// Creates a cursor that lazily initializes a value from each row SQL that only reads returns.
  ///
  /// The cursor must be consumed inside this transaction. Its lazy adapters and terminal
  /// operations are those of every ``OrbitDatabaseCursor``.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var cursor = try transaction.fetchCursor("SELECT title FROM reminders", as: String.self)
  ///   while let title = try cursor.next() { print(title) }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run, which must only read.
  ///   - type: The type to initialize from each row.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL. See
  ///     ``OrbitDatabaseReadTransaction/rowCursor(_:cached:)``.
  /// - Returns: A cursor over the initialized values, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    as type: Value.Type,
    cached: Bool = false
  ) throws -> OrbitDatabaseRowDecodingCursor<RowCursor, Value> {
    OrbitDatabaseRowDecodingCursor(base: try rowCursor(sql, cached: cached))
  }
}

extension OrbitDatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor that lazily initializes a value from each row SQL that may write returns,
  /// such as from a `RETURNING` clause.
  ///
  /// The cursor must be consumed inside this transaction.
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   var cursor = try transaction.executeCursor(
  ///     "DELETE FROM reminders WHERE is_completed RETURNING id, title",
  ///     as: ReminderSummary.self
  ///   )
  ///   let deleted = try cursor.collect()
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - type: The type to initialize from each row.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL. See
  ///     ``OrbitDatabaseReadTransaction/rowCursor(_:cached:)``.
  /// - Returns: A cursor over the initialized values, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func executeCursor<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    as type: Value.Type,
    cached: Bool = false
  ) throws -> OrbitDatabaseRowDecodingCursor<RowCursor, Value> {
    OrbitDatabaseRowDecodingCursor(base: try executeRowCursor(sql, cached: cached))
  }
}
