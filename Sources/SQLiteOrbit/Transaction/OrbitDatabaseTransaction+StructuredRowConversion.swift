#if StructuredQueries
  public import StructuredQueriesSQLite

  extension OrbitDatabaseReadTransaction
  where Self: ~Copyable, Self: ~Escapable, Row: OrbitDatabaseStructuredRow {
    /// Decodes every raw SQL result as a Structured Queries table or selection.
    ///
    /// Both `@Table` and `@Selection` types qualify without another conformance. Columns decode
    /// positionally in the type's expected order, using its declared query representations. SQL
    /// must return that projection and the storage classes those representations expect; names
    /// are used only for diagnostics. The result is `Value.QueryOutput`, which can differ from
    /// `Value`, for example when decoding a table alias.
    public borrowing func fetchAll<Value: Table>(
      _ sql: SQL,
      asStructuredRow type: Value.Type
    ) throws -> [Value.QueryOutput] {
      try fetchAll(sql) { row in try row.decode(Value.self) }
    }

    /// Decodes the first raw SQL result as a Structured Queries table or selection.
    ///
    /// Returns `nil` for no rows. Columns use the same positional contract as
    /// ``fetchAll(_:asStructuredRow:)``. Decoding and statement errors propagate.
    public borrowing func fetchOne<Value: Table>(
      _ sql: SQL,
      asStructuredRow type: Value.Type
    ) throws -> Value.QueryOutput? {
      try fetchOne(sql) { row in try row.decode(Value.self) }
    }

    /// Creates a cursor that lazily decodes raw SQL as a Structured Queries table or selection.
    ///
    /// Columns must use the type's expected order and query representations. The cursor supports
    /// all ``OrbitDatabaseCursor`` algorithms and must be consumed inside the transaction.
    /// `cached` follows ``OrbitDatabaseReadTransaction/rowCursor(_:cached:)`` sharing rules.
    @_lifetime(borrow self)
    public borrowing func fetchCursor<Value: Table>(
      _ sql: SQL,
      asStructuredRow type: Value.Type,
      cached: Bool = false
    ) throws -> OrbitDatabaseQueryCursor<RowCursor, Value> {
      OrbitDatabaseQueryCursor(base: try rowCursor(sql, cached: cached))
    }
  }

  extension OrbitDatabaseWriteTransaction
  where Self: ~Copyable, Self: ~Escapable, Row: OrbitDatabaseStructuredRow {
    /// Decodes every returned row of SQL that may write as a Structured Queries table or selection.
    ///
    /// A `RETURNING` projection must match the type's column order and declared query
    /// representations. Results have type `Value.QueryOutput`, with no additional row conformance.
    public borrowing func fetchAll<Value: Table>(
      _ sql: SQL,
      asStructuredRow type: Value.Type
    ) throws -> [Value.QueryOutput] {
      try fetchAll(sql) { row in try row.decode(Value.self) }
    }

    /// Decodes the first returned row of SQL that may write as a Structured Queries value.
    ///
    /// Returns `nil` for no rows. Reading only one `RETURNING` row does not limit the write's
    /// changes. The projection must match the type's column order and query representations.
    public borrowing func fetchOne<Value: Table>(
      _ sql: SQL,
      asStructuredRow type: Value.Type
    ) throws -> Value.QueryOutput? {
      try fetchOne(sql) { row in try row.decode(Value.self) }
    }

    /// Creates a cursor that decodes returned rows of SQL that may write as Structured Queries values.
    ///
    /// Use this for `RETURNING` projections matching the type's column order and query
    /// representations. The cursor must be consumed inside the transaction.
    @_lifetime(borrow self)
    public borrowing func executeCursor<Value: Table>(
      _ sql: SQL,
      asStructuredRow type: Value.Type,
      cached: Bool = false
    ) throws -> OrbitDatabaseQueryCursor<RowCursor, Value> {
      OrbitDatabaseQueryCursor(base: try executeRowCursor(sql, cached: cached))
    }
  }
#endif
