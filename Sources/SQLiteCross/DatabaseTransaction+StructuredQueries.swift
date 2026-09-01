import StructuredQueriesSQLite

extension DatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor that lazily decodes each value produced by a Structured Queries statement.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<S: DatabaseReadStatement>(
    _ statement: S
  ) throws -> DatabaseQueryCursor<RowCursor, S.QueryValue>
  where S.QueryValue: QueryRepresentable {
    DatabaseQueryCursor(base: try rowCursor(statement))
  }

  /// Creates a cursor that lazily decodes each tuple produced by a Structured Queries statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func fetchCursor<S: DatabaseReadStatement, each Value: QueryRepresentable>(
    _ statement: S
  ) throws -> DatabaseTupleQueryCursor<RowCursor, repeat each Value>
  where S.QueryValue == (repeat each Value) {
    DatabaseTupleQueryCursor(base: try rowCursor(statement))
  }

  /// Creates a cursor that lazily decodes each table value from a select statement that has no
  /// explicit projection.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<S: SelectStatement>(
    _ statement: S
  ) throws -> DatabaseQueryCursor<RowCursor, S.From>
  where S: DatabaseReadStatement, S.QueryValue == (), S.Joins == () {
    DatabaseQueryCursor(base: try rowCursor(statement))
  }
}

extension DatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor that lazily decodes each value returned by a write statement.
  @_lifetime(borrow self)
  public borrowing func executeCursor<S: DatabaseWriteStatement>(
    _ statement: S
  ) throws -> DatabaseQueryCursor<RowCursor, S.QueryValue>
  where S.QueryValue: QueryRepresentable {
    DatabaseQueryCursor(base: try executeRowCursor(statement))
  }

  /// Creates a cursor that lazily decodes each tuple returned by a write statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func executeCursor<
    S: DatabaseWriteStatement,
    each Value: QueryRepresentable
  >(
    _ statement: S
  ) throws -> DatabaseTupleQueryCursor<RowCursor, repeat each Value>
  where S.QueryValue == (repeat each Value) {
    DatabaseTupleQueryCursor(base: try executeRowCursor(statement))
  }
}

extension DatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Fetches every value produced by a Structured Queries statement.
  public borrowing func fetchAll<S: DatabaseReadStatement>(
    _ statement: S
  ) throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable {
    var values: [S.QueryValue.QueryOutput] = []
    var cursor = try fetchCursor(statement)
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  /// Fetches the first value produced by a Structured Queries statement.
  public borrowing func fetchOne<S: DatabaseReadStatement>(
    _ statement: S
  ) throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable {
    var cursor = try fetchCursor(statement)
    return try cursor.next()
  }

  /// Fetches every tuple produced by a Structured Queries statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<S: DatabaseReadStatement, each Value: QueryRepresentable>(
    _ statement: S
  ) throws -> [(repeat (each Value).QueryOutput)]
  where S.QueryValue == (repeat each Value) {
    var values: [(repeat (each Value).QueryOutput)] = []
    var cursor = try fetchCursor(statement)
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  /// Fetches the first tuple produced by a Structured Queries statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<S: DatabaseReadStatement, each Value: QueryRepresentable>(
    _ statement: S
  ) throws -> (repeat (each Value).QueryOutput)?
  where S.QueryValue == (repeat each Value) {
    var cursor = try fetchCursor(statement)
    return try cursor.next()
  }

  /// Fetches every table value from a select statement that has no explicit projection.
  public borrowing func fetchAll<S: SelectStatement>(
    _ statement: S
  ) throws -> [S.From.QueryOutput]
  where S: DatabaseReadStatement, S.QueryValue == (), S.Joins == () {
    var values: [S.From.QueryOutput] = []
    var cursor = try fetchCursor(statement)
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  /// Fetches the first table value from a select statement that has no explicit projection.
  public borrowing func fetchOne<S: SelectStatement>(
    _ statement: S
  ) throws -> S.From.QueryOutput?
  where S: DatabaseReadStatement, S.QueryValue == (), S.Joins == () {
    var cursor = try fetchCursor(statement.asSelect().limit(1))
    return try cursor.next()
  }
}

extension DatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Fetches every value produced by a Structured Queries write statement.
  public borrowing func fetchAll<S: DatabaseWriteStatement>(
    _ statement: S
  ) throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable {
    var values: [S.QueryValue.QueryOutput] = []
    var cursor = try executeCursor(statement)
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  /// Fetches the first value produced by a Structured Queries write statement.
  public borrowing func fetchOne<S: DatabaseWriteStatement>(
    _ statement: S
  ) throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable {
    var cursor = try executeCursor(statement)
    return try cursor.next()
  }

  /// Fetches every tuple produced by a Structured Queries write statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<
    S: DatabaseWriteStatement,
    each Value: QueryRepresentable
  >(
    _ statement: S
  ) throws -> [(repeat (each Value).QueryOutput)]
  where S.QueryValue == (repeat each Value) {
    var values: [(repeat (each Value).QueryOutput)] = []
    var cursor = try executeCursor(statement)
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  /// Fetches the first tuple produced by a Structured Queries write statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<
    S: DatabaseWriteStatement,
    each Value: QueryRepresentable
  >(
    _ statement: S
  ) throws -> (repeat (each Value).QueryOutput)?
  where S.QueryValue == (repeat each Value) {
    var cursor = try executeCursor(statement)
    return try cursor.next()
  }

  /// Fetches every value produced by unchecked raw SQL.
  public borrowing func fetchAll<Value: QueryRepresentable>(
    _ statement: SQLQueryExpression<Value>
  ) throws -> [Value.QueryOutput] {
    var values: [Value.QueryOutput] = []
    var cursor = try executeCursor(statement)
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  /// Fetches the first value produced by unchecked raw SQL.
  public borrowing func fetchOne<Value: QueryRepresentable>(
    _ statement: SQLQueryExpression<Value>
  ) throws -> Value.QueryOutput? {
    var cursor = try executeCursor(statement)
    return try cursor.next()
  }

  /// Fetches every tuple produced by unchecked raw SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<each Value: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each Value)>
  ) throws -> [(repeat (each Value).QueryOutput)] {
    var values: [(repeat (each Value).QueryOutput)] = []
    var cursor = try executeCursor(statement)
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  /// Fetches the first tuple produced by unchecked raw SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<each Value: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each Value)>
  ) throws -> (repeat (each Value).QueryOutput)? {
    var cursor = try executeCursor(statement)
    return try cursor.next()
  }
}
