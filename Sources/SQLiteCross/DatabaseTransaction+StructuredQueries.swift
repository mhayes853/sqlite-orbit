import StructuredQueries

extension DatabaseTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Executes a Structured Queries statement and returns its affected-row count.
  @discardableResult
  public borrowing func execute<S: Statement>(_ statement: S) throws -> Int
  where S.QueryValue == () {
    try execute(statement.query)
  }

  /// Fetches every value produced by a Structured Queries statement.
  public borrowing func fetchAll<S: Statement>(
    _ statement: S
  ) throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable {
    var values: [S.QueryValue.QueryOutput] = []
    try query(statement.query) { row in
      values.append(try row.decode(S.QueryValue.self))
      return .next
    }
    return values
  }

  /// Fetches the first value produced by a Structured Queries statement.
  public borrowing func fetchOne<S: Statement>(
    _ statement: S
  ) throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable {
    var value: S.QueryValue.QueryOutput?
    try query(statement.query) { row in
      value = try row.decode(S.QueryValue.self)
      return .stop
    }
    return value
  }

  /// Fetches every tuple produced by a Structured Queries statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<S: Statement, each Value: QueryRepresentable>(
    _ statement: S
  ) throws -> [(repeat (each Value).QueryOutput)]
  where S.QueryValue == (repeat each Value) {
    var values: [(repeat (each Value).QueryOutput)] = []
    try query(statement.query) { row in
      values.append(try row.decode((repeat each Value).self))
      return .next
    }
    return values
  }

  /// Fetches the first tuple produced by a Structured Queries statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<S: Statement, each Value: QueryRepresentable>(
    _ statement: S
  ) throws -> (repeat (each Value).QueryOutput)?
  where S.QueryValue == (repeat each Value) {
    var value: (repeat (each Value).QueryOutput)?
    try query(statement.query) { row in
      value = try row.decode((repeat each Value).self)
      return .stop
    }
    return value
  }

  /// Fetches every table value from a select statement that has no explicit projection.
  public borrowing func fetchAll<S: SelectStatement>(
    _ statement: S
  ) throws -> [S.From.QueryOutput]
  where S.QueryValue == (), S.Joins == () {
    var values: [S.From.QueryOutput] = []
    try query(statement.query) { row in
      values.append(try row.decode(S.From.self))
      return .next
    }
    return values
  }

  /// Fetches the first table value from a select statement that has no explicit projection.
  public borrowing func fetchOne<S: SelectStatement>(
    _ statement: S
  ) throws -> S.From.QueryOutput?
  where S.QueryValue == (), S.Joins == () {
    var value: S.From.QueryOutput?
    try query(statement.asSelect().limit(1).query) { row in
      value = try row.decode(S.From.self)
      return .stop
    }
    return value
  }
}
