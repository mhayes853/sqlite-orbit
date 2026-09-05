public import StructuredQueriesSQLite

/// Thrown by ``DatabaseReadTransaction/find(_:key:)`` when no row has the given primary key.
public struct DatabaseRecordNotFoundError: Error, Sendable {
  public init() {}
}

// Statements come in four shapes, and each needs its own decoding. A statement either projects a
// single value, projects a tuple of values, or projects nothing at all, in which case its rows
// decode to its `FROM` table plus whatever tables are joined to it. Raw SQL takes the first two
// shapes, but has no type in common with the select statements, so it is spelled out again.
//
// These are written once, on the read transaction. `DatabaseWriteTransaction` refines
// `DatabaseReadTransaction`, so write transactions inherit all four.

// MARK: - Cursors

extension DatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor that lazily decodes each value produced by a select statement.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<QueryValue>,
    cached: Bool = false
  ) throws -> DatabaseQueryCursor<RowCursor, QueryValue> {
    DatabaseQueryCursor(base: try rowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each tuple produced by a select statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func fetchCursor<each QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<(repeat each QueryValue)>,
    cached: Bool = false
  ) throws -> DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue> {
    DatabaseTupleQueryCursor(base: try rowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each table value from a select statement that has no
  /// explicit projection.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<S: SelectStatement>(
    _ statement: S,
    cached: Bool = false
  ) throws -> DatabaseQueryCursor<RowCursor, S.From>
  where S.QueryValue == (), S.Joins == () {
    DatabaseQueryCursor(base: try rowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each joined row from a select statement that has no
  /// explicit projection.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func fetchCursor<S: SelectStatement, each J: Table>(
    _ statement: S,
    cached: Bool = false
  ) throws -> DatabaseTupleQueryCursor<RowCursor, S.From, repeat each J>
  where S.QueryValue == (), S.Joins == (repeat each J) {
    DatabaseTupleQueryCursor(base: try rowCursor(statement.selectStar(), cached: cached))
  }

  /// Creates a cursor that lazily decodes each value produced by raw SQL.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<QueryValue>,
    cached: Bool = false
  ) throws -> DatabaseQueryCursor<RowCursor, QueryValue> {
    DatabaseQueryCursor(base: try rowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each tuple produced by raw SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func fetchCursor<each QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each QueryValue)>,
    cached: Bool = false
  ) throws -> DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue> {
    DatabaseTupleQueryCursor(base: try rowCursor(statement, cached: cached))
  }
}

// MARK: - Eager fetches

// Eager fetches consume and discard their cursor before returning, so they can share the
// connection's cached statement. The tuple shapes spell out their loops because the compiler
// cannot see through a cursor's `Element` when it is a pack expansion.

extension DatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Fetches every value produced by a select statement.
  public borrowing func fetchAll<QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<QueryValue>
  ) throws -> [QueryValue.QueryOutput] {
    try fetchCursor(statement, cached: true).collect()
  }

  /// Fetches the first value produced by a select statement.
  public borrowing func fetchOne<QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<QueryValue>
  ) throws -> QueryValue.QueryOutput? {
    try fetchCursor(statement, cached: true).first()
  }

  /// Fetches every tuple produced by a select statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<each QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<(repeat each QueryValue)>
  ) throws -> [(repeat (each QueryValue).QueryOutput)] {
    var values: [(repeat (each QueryValue).QueryOutput)] = []
    var cursor = DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue>(
      base: try rowCursor(statement, cached: true)
    )
    try cursor.forEach { values.append($0) }
    return values
  }

  /// Fetches the first tuple produced by a select statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<each QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<(repeat each QueryValue)>
  ) throws -> (repeat (each QueryValue).QueryOutput)? {
    var cursor = DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue>(
      base: try rowCursor(statement, cached: true)
    )
    return try cursor.next()
  }

  /// Fetches every table value from a select statement that has no explicit projection.
  public borrowing func fetchAll<S: SelectStatement>(
    _ statement: S
  ) throws -> [S.From.QueryOutput]
  where S.QueryValue == (), S.Joins == () {
    try fetchCursor(statement, cached: true).collect()
  }

  /// Fetches the first table value from a select statement that has no explicit projection.
  public borrowing func fetchOne<S: SelectStatement>(
    _ statement: S
  ) throws -> S.From.QueryOutput?
  where S.QueryValue == (), S.Joins == () {
    try fetchCursor(statement.asSelect().limit(1), cached: true).first()
  }

  /// Fetches every joined row from a select statement that has no explicit projection.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<S: SelectStatement, each J: Table>(
    _ statement: S
  ) throws -> [(S.From.QueryOutput, repeat (each J).QueryOutput)]
  where S.QueryValue == (), S.Joins == (repeat each J) {
    try fetchAll(statement.selectStar())
  }

  /// Fetches the first joined row from a select statement that has no explicit projection.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<S: SelectStatement, each J: Table>(
    _ statement: S
  ) throws -> (S.From.QueryOutput, repeat (each J).QueryOutput)?
  where S.QueryValue == (), S.Joins == (repeat each J) {
    try fetchOne(statement.asSelect().limit(1).selectStar())
  }

  /// Returns the number of rows a select statement produces.
  public borrowing func fetchCount<S: SelectStatement>(
    _ statement: S
  ) throws -> Int
  where S.QueryValue == (), S.Joins == () {
    try fetchOne(statement.asSelect().count()) ?? 0
  }

  /// Fetches every value produced by raw SQL.
  public borrowing func fetchAll<QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<QueryValue>
  ) throws -> [QueryValue.QueryOutput] {
    try fetchCursor(statement, cached: true).collect()
  }

  /// Fetches the first value produced by raw SQL.
  public borrowing func fetchOne<QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<QueryValue>
  ) throws -> QueryValue.QueryOutput? {
    try fetchCursor(statement, cached: true).first()
  }

  /// Fetches every tuple produced by raw SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<each QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each QueryValue)>
  ) throws -> [(repeat (each QueryValue).QueryOutput)] {
    var values: [(repeat (each QueryValue).QueryOutput)] = []
    var cursor = DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue>(
      base: try rowCursor(statement, cached: true)
    )
    try cursor.forEach { values.append($0) }
    return values
  }

  /// Fetches the first tuple produced by raw SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<each QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each QueryValue)>
  ) throws -> (repeat (each QueryValue).QueryOutput)? {
    var cursor = DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue>(
      base: try rowCursor(statement, cached: true)
    )
    return try cursor.next()
  }

  /// Fetches the row with the given primary key.
  ///
  /// - Throws: ``DatabaseRecordNotFoundError`` if no row has that primary key.
  public borrowing func find<S: SelectStatement>(
    _ statement: S,
    key primaryKey: some QueryExpression<S.From.PrimaryKey>
  ) throws -> S.From.QueryOutput
  where S.QueryValue == (), S.Joins == (), S.From: PrimaryKeyedTable {
    guard let record = try fetchOne(statement.asSelect().find(primaryKey)) else {
      throw DatabaseRecordNotFoundError()
    }
    return record
  }
}

// MARK: - Statements that return rows from a write

extension DatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor that lazily decodes each value returned by a write statement, such as one
  /// with a `RETURNING` clause.
  @_lifetime(borrow self)
  public borrowing func executeCursor<QueryValue: QueryRepresentable>(
    _ statement: some Statement<QueryValue>,
    cached: Bool = false
  ) throws -> DatabaseQueryCursor<RowCursor, QueryValue> {
    DatabaseQueryCursor(base: try executeRowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each tuple returned by a write statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func executeCursor<each QueryValue: QueryRepresentable>(
    _ statement: some Statement<(repeat each QueryValue)>,
    cached: Bool = false
  ) throws -> DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue> {
    DatabaseTupleQueryCursor(base: try executeRowCursor(statement, cached: cached))
  }

  /// Fetches every value returned by a write statement.
  public borrowing func fetchAll<QueryValue: QueryRepresentable>(
    _ statement: some Statement<QueryValue>
  ) throws -> [QueryValue.QueryOutput] {
    try executeCursor(statement, cached: true).collect()
  }

  /// Fetches the first value returned by a write statement.
  public borrowing func fetchOne<QueryValue: QueryRepresentable>(
    _ statement: some Statement<QueryValue>
  ) throws -> QueryValue.QueryOutput? {
    try executeCursor(statement, cached: true).first()
  }

  /// Fetches every tuple returned by a write statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<each QueryValue: QueryRepresentable>(
    _ statement: some Statement<(repeat each QueryValue)>
  ) throws -> [(repeat (each QueryValue).QueryOutput)] {
    var values: [(repeat (each QueryValue).QueryOutput)] = []
    var cursor = DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue>(
      base: try executeRowCursor(statement, cached: true)
    )
    try cursor.forEach { values.append($0) }
    return values
  }

  /// Fetches the first tuple returned by a write statement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<each QueryValue: QueryRepresentable>(
    _ statement: some Statement<(repeat each QueryValue)>
  ) throws -> (repeat (each QueryValue).QueryOutput)? {
    var cursor = DatabaseTupleQueryCursor<RowCursor, repeat each QueryValue>(
      base: try executeRowCursor(statement, cached: true)
    )
    return try cursor.next()
  }
}
