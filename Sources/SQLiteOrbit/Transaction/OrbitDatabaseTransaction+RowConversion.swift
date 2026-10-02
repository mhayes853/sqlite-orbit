extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Initializes a value from every row raw SQL returns, in result order.
  ///
  /// Unlike `as:`, which reads the first column, `asRow:` passes the entire row to the type's
  /// initializer. Initialization and statement errors propagate.
  public borrowing func fetchAll<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    asRow type: Value.Type
  ) throws -> [Value] {
    try fetchAll(sql) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Initializes a value from the first row, or returns `nil` when there are no rows.
  public borrowing func fetchOne<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    asRow type: Value.Type
  ) throws -> Value? {
    try fetchOne(sql) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Creates a cursor that lazily initializes an owned value from each row raw SQL returns.
  ///
  /// The cursor must be consumed inside this transaction. `cached` follows the prepared-statement
  /// sharing rules of ``OrbitDatabaseReadTransaction/rowCursor(_:cached:)``.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    asRow type: Value.Type,
    cached: Bool = false
  ) throws -> OrbitDatabaseRowDecodingCursor<RowCursor, Value> {
    OrbitDatabaseRowDecodingCursor(base: try rowCursor(sql, cached: cached))
  }
}

extension OrbitDatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Initializes values from all returned rows, including those of a write's `RETURNING` clause.
  public borrowing func fetchAll<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    asRow type: Value.Type
  ) throws -> [Value] {
    try fetchAll(sql) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Initializes a value from the first returned row of SQL that may write.
  ///
  /// Returns `nil` for no rows. Reading one `RETURNING` row does not limit the write's changes.
  public borrowing func fetchOne<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    asRow type: Value.Type
  ) throws -> Value? {
    try fetchOne(sql) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Creates a cursor that lazily initializes values from SQL that may write.
  ///
  /// Use this for `RETURNING` statements. The cursor must be consumed inside this transaction.
  @_lifetime(borrow self)
  public borrowing func executeCursor<Value: ConvertibleFromOrbitDatabaseRow>(
    _ sql: SQL,
    asRow type: Value.Type,
    cached: Bool = false
  ) throws -> OrbitDatabaseRowDecodingCursor<RowCursor, Value> {
    OrbitDatabaseRowDecodingCursor(base: try executeRowCursor(sql, cached: cached))
  }
}
