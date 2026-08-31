import StructuredQueries

extension DatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Fetches every value produced by a Structured Queries statement.
  public borrowing func fetchAll<S: DatabaseReadStatement>(
    _ statement: S
  ) throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable {
    var values: [S.QueryValue.QueryOutput] = []
    try query(statement) { row in
      values.append(try row.decode(S.QueryValue.self))
      return .next
    }
    return values
  }

  /// Fetches the first value produced by a Structured Queries statement.
  public borrowing func fetchOne<S: DatabaseReadStatement>(
    _ statement: S
  ) throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable {
    var value: S.QueryValue.QueryOutput?
    try query(statement) { row in
      value = try row.decode(S.QueryValue.self)
      return .stop
    }
    return value
  }

  /// Fetches every tuple produced by a Structured Queries statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<S: DatabaseReadStatement, each Value: QueryRepresentable>(
    _ statement: S
  ) throws -> [(repeat (each Value).QueryOutput)]
  where S.QueryValue == (repeat each Value) {
    var values: [(repeat (each Value).QueryOutput)] = []
    try query(statement) { row in
      values.append(try row.decode((repeat each Value).self))
      return .next
    }
    return values
  }

  /// Fetches the first tuple produced by a Structured Queries statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<S: DatabaseReadStatement, each Value: QueryRepresentable>(
    _ statement: S
  ) throws -> (repeat (each Value).QueryOutput)?
  where S.QueryValue == (repeat each Value) {
    var value: (repeat (each Value).QueryOutput)?
    try query(statement) { row in
      value = try row.decode((repeat each Value).self)
      return .stop
    }
    return value
  }

  /// Fetches every table value from a select statement that has no explicit projection.
  public borrowing func fetchAll<S: SelectStatement>(
    _ statement: S
  ) throws -> [S.From.QueryOutput]
  where S: DatabaseReadStatement, S.QueryValue == (), S.Joins == () {
    var values: [S.From.QueryOutput] = []
    try query(statement) { row in
      values.append(try row.decode(S.From.self))
      return .next
    }
    return values
  }

  /// Fetches the first table value from a select statement that has no explicit projection.
  public borrowing func fetchOne<S: SelectStatement>(
    _ statement: S
  ) throws -> S.From.QueryOutput?
  where S: DatabaseReadStatement, S.QueryValue == (), S.Joins == () {
    var value: S.From.QueryOutput?
    try query(statement.asSelect().limit(1)) { row in
      value = try row.decode(S.From.self)
      return .stop
    }
    return value
  }
}

extension DatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Fetches every value produced by a Structured Queries write statement.
  public borrowing func fetchAll<S: DatabaseWriteStatement>(
    _ statement: S
  ) throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable {
    var values: [S.QueryValue.QueryOutput] = []
    try execute(statement) { row in
      values.append(try row.decode(S.QueryValue.self))
      return .next
    }
    return values
  }

  /// Fetches the first value produced by a Structured Queries write statement.
  public borrowing func fetchOne<S: DatabaseWriteStatement>(
    _ statement: S
  ) throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable {
    var value: S.QueryValue.QueryOutput?
    try execute(statement) { row in
      value = try row.decode(S.QueryValue.self)
      return .stop
    }
    return value
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
    try execute(statement) { row in
      values.append(try row.decode((repeat each Value).self))
      return .next
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
    var value: (repeat (each Value).QueryOutput)?
    try execute(statement) { row in
      value = try row.decode((repeat each Value).self)
      return .stop
    }
    return value
  }

  /// Fetches every value produced by unchecked raw SQL.
  public borrowing func fetchAll<Value: QueryRepresentable>(
    _ statement: SQLQueryExpression<Value>
  ) throws -> [Value.QueryOutput] {
    var values: [Value.QueryOutput] = []
    try execute(statement) { row in
      values.append(try row.decode(Value.self))
      return .next
    }
    return values
  }

  /// Fetches the first value produced by unchecked raw SQL.
  public borrowing func fetchOne<Value: QueryRepresentable>(
    _ statement: SQLQueryExpression<Value>
  ) throws -> Value.QueryOutput? {
    var value: Value.QueryOutput?
    try execute(statement) { row in
      value = try row.decode(Value.self)
      return .stop
    }
    return value
  }

  /// Fetches every tuple produced by unchecked raw SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<each Value: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each Value)>
  ) throws -> [(repeat (each Value).QueryOutput)] {
    var values: [(repeat (each Value).QueryOutput)] = []
    try execute(statement) { row in
      values.append(try row.decode((repeat each Value).self))
      return .next
    }
    return values
  }

  /// Fetches the first tuple produced by unchecked raw SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<each Value: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each Value)>
  ) throws -> (repeat (each Value).QueryOutput)? {
    var value: (repeat (each Value).QueryOutput)?
    try execute(statement) { row in
      value = try row.decode((repeat each Value).self)
      return .stop
    }
    return value
  }
}
