public import StructuredQueriesSQLite

/// Thrown by ``OrbitDatabaseReadTransaction/find(_:key:)`` when no row has the given primary key.
///
/// ```swift
/// do {
///   let reminder = try transaction.find(Reminder.all, key: 42)
/// } catch is OrbitDatabaseRecordNotFoundError {
///   print("no reminder 42")
/// }
/// ```
public struct OrbitDatabaseRecordNotFoundError: Error, Sendable {
  /// Creates the error.
  public init() {}
}

// Statements come in four shapes, and each needs its own decoding. A statement either projects a
// single value, projects a tuple of values, or projects nothing at all, in which case its rows
// decode to its `FROM` table plus whatever tables are joined to it. Raw SQL takes the first two
// shapes, but has no type in common with the select statements, so it is spelled out again.
//
// These are written once, on the read transaction. `OrbitDatabaseWriteTransaction` refines
// `OrbitDatabaseReadTransaction`, so write transactions inherit all four.

// MARK: - Cursors

extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor that lazily decodes each value produced by a select statement.
  ///
  /// Nothing is read until the cursor is advanced, so a result set too large to hold in memory can
  /// still be walked. ``fetchAll(_:)`` is the eager equivalent.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var cursor = try transaction.fetchCursor(Reminder.select(\.title))
  ///   try cursor.forEach { print($0) }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL. Pass `true` only
  ///     when the cursor is fully consumed before another over the same SQL is created.
  /// - Returns: A cursor over the decoded values.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<QueryValue>,
    cached: Bool = false
  ) throws -> OrbitDatabaseQueryCursor<RowCursor, QueryValue> {
    OrbitDatabaseQueryCursor(base: try rowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each tuple produced by a select statement.
  ///
  /// ```swift
  /// var cursor = try transaction.fetchCursor(Reminder.select { ($0.id, $0.title) })
  /// while let (id, title) = try cursor.next() { print(id, title) }
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the decoded tuples.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func fetchCursor<each QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<(repeat each QueryValue)>,
    cached: Bool = false
  ) throws -> OrbitDatabaseTupleQueryCursor<RowCursor, repeat each QueryValue> {
    OrbitDatabaseTupleQueryCursor(base: try rowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each table value from a select statement that has no
  /// explicit projection.
  ///
  /// ```swift
  /// var cursor = try transaction.fetchCursor(Reminder.where { !$0.isCompleted })
  /// while let reminder = try cursor.next() { print(reminder.title) }
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the decoded table values.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<S: SelectStatement>(
    _ statement: S,
    cached: Bool = false
  ) throws -> OrbitDatabaseQueryCursor<RowCursor, S.From>
  where S.QueryValue == (), S.Joins == () {
    OrbitDatabaseQueryCursor(base: try rowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each joined row from a select statement that has no
  /// explicit projection.
  ///
  /// The statement's `FROM` table comes first, then each joined table in the order it was joined.
  ///
  /// ```swift
  /// var cursor = try transaction.fetchCursor(Reminder.join(List.all) { $0.listID.eq($1.id) })
  /// while let (reminder, list) = try cursor.next() { print(reminder.title, list.name) }
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the decoded rows.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func fetchCursor<S: SelectStatement, each J: Table>(
    _ statement: S,
    cached: Bool = false
  ) throws -> OrbitDatabaseTupleQueryCursor<RowCursor, S.From, repeat each J>
  where S.QueryValue == (), S.Joins == (repeat each J) {
    OrbitDatabaseTupleQueryCursor(base: try rowCursor(statement.selectStar(), cached: cached))
  }

  /// Creates a cursor that lazily decodes each value produced by raw SQL.
  ///
  /// ```swift
  /// var cursor = try transaction.fetchCursor(#sql("SELECT title FROM reminders", as: String.self))
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The SQL to run, which the caller is stating only reads.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the decoded values.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func fetchCursor<QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<QueryValue>,
    cached: Bool = false
  ) throws -> OrbitDatabaseQueryCursor<RowCursor, QueryValue> {
    OrbitDatabaseQueryCursor(base: try rowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each tuple produced by raw SQL.
  ///
  /// ```swift
  /// var cursor = try transaction.fetchCursor(
  ///   #sql("SELECT id, title FROM reminders", as: (Int, String).self)
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The SQL to run, which the caller is stating only reads.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the decoded tuples.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func fetchCursor<each QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each QueryValue)>,
    cached: Bool = false
  ) throws -> OrbitDatabaseTupleQueryCursor<RowCursor, repeat each QueryValue> {
    OrbitDatabaseTupleQueryCursor(base: try rowCursor(statement, cached: cached))
  }
}

// MARK: - Eager fetches

// Eager fetches consume and discard their cursor before returning, so they can share the
// connection's cached statement. The tuple shapes go through `collectTuples`/`firstTuple` because
// the compiler cannot see through a cursor's `Element` when it is a pack expansion.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension OrbitDatabaseRowCursor where Self: ~Copyable, Self: ~Escapable {
  /// Decodes every remaining row into a tuple.
  mutating func collectTuples<each Value: QueryRepresentable>(
    _ type: (repeat each Value).Type
  ) throws -> [(repeat (each Value).QueryOutput)] {
    var values: [(repeat (each Value).QueryOutput)] = []
    try forEach { row in values.append(try row.decode((repeat each Value).self)) }
    return values
  }

  /// Decodes the next row into a tuple, or returns `nil` when the cursor is exhausted.
  mutating func firstTuple<each Value: QueryRepresentable>(
    _ type: (repeat each Value).Type
  ) throws -> (repeat (each Value).QueryOutput)? {
    guard var row = try next() else { return nil }
    return try row.decode((repeat each Value).self)
  }
}

extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Fetches every value produced by a select statement.
  ///
  /// ```swift
  /// let titles = try await database.read { transaction in
  ///   try transaction.fetchAll(Reminder.select(\.title))
  /// }
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: Every decoded value, in the order the statement produced it.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
  public borrowing func fetchAll<QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<QueryValue>
  ) throws -> [QueryValue.QueryOutput] {
    try fetchCursor(statement, cached: true).collect()
  }

  /// Fetches the first value produced by a select statement.
  ///
  /// ```swift
  /// let count = try transaction.fetchOne(Reminder.all.count()) ?? 0
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: The first decoded value, or `nil` when the statement produced no row.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
  public borrowing func fetchOne<QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<QueryValue>
  ) throws -> QueryValue.QueryOutput? {
    try fetchCursor(statement, cached: true).first()
  }

  /// Fetches every tuple produced by a select statement.
  ///
  /// ```swift
  /// let rows = try transaction.fetchAll(Reminder.select { ($0.id, $0.title) })
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: Every decoded tuple, in the order the statement produced it.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<each QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<(repeat each QueryValue)>
  ) throws -> [(repeat (each QueryValue).QueryOutput)] {
    var cursor = try rowCursor(statement, cached: true)
    return try cursor.collectTuples((repeat each QueryValue).self)
  }

  /// Fetches the first tuple produced by a select statement.
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: The first decoded tuple, or `nil` when the statement produced no row.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<each QueryValue: QueryRepresentable>(
    _ statement: some PartialSelectStatement<(repeat each QueryValue)>
  ) throws -> (repeat (each QueryValue).QueryOutput)? {
    var cursor = try rowCursor(statement, cached: true)
    return try cursor.firstTuple((repeat each QueryValue).self)
  }

  /// Fetches every table value from a select statement that has no explicit projection.
  ///
  /// ```swift
  /// let pending = try transaction.fetchAll(Reminder.where { !$0.isCompleted })
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: Every decoded row of the statement's `FROM` table.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
  public borrowing func fetchAll<S: SelectStatement>(
    _ statement: S
  ) throws -> [S.From.QueryOutput]
  where S.QueryValue == (), S.Joins == () {
    try fetchCursor(statement, cached: true).collect()
  }

  /// Fetches the first table value from a select statement that has no explicit projection.
  ///
  /// A `LIMIT 1` is added, so only one row is read.
  ///
  /// ```swift
  /// let newest = try transaction.fetchOne(Reminder.order { $0.id.desc() })
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: The first decoded row, or `nil` when the statement produced none.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
  public borrowing func fetchOne<S: SelectStatement>(
    _ statement: S
  ) throws -> S.From.QueryOutput?
  where S.QueryValue == (), S.Joins == () {
    try fetchCursor(statement.asSelect().limit(1), cached: true).first()
  }

  /// Fetches every joined row from a select statement that has no explicit projection.
  ///
  /// ```swift
  /// let rows = try transaction.fetchAll(Reminder.join(List.all) { $0.listID.eq($1.id) })
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: Every decoded row, its `FROM` table first and each joined table after it.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<S: SelectStatement, each J: Table>(
    _ statement: S
  ) throws -> [(S.From.QueryOutput, repeat (each J).QueryOutput)]
  where S.QueryValue == (), S.Joins == (repeat each J) {
    try fetchAll(statement.selectStar())
  }

  /// Fetches the first joined row from a select statement that has no explicit projection.
  ///
  /// A `LIMIT 1` is added, so only one row is read.
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: The first decoded row, or `nil` when the statement produced none.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<S: SelectStatement, each J: Table>(
    _ statement: S
  ) throws -> (S.From.QueryOutput, repeat (each J).QueryOutput)?
  where S.QueryValue == (), S.Joins == (repeat each J) {
    try fetchOne(statement.asSelect().limit(1).selectStar())
  }

  /// Returns the number of rows a select statement produces.
  ///
  /// The counting is done by SQLite, so no row is decoded.
  ///
  /// ```swift
  /// let pending = try transaction.fetchCount(Reminder.where { !$0.isCompleted })
  /// ```
  ///
  /// - Parameter statement: The statement to count.
  /// - Returns: How many rows the statement would produce.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  public borrowing func fetchCount<S: SelectStatement>(
    _ statement: S
  ) throws -> Int
  where S.QueryValue == (), S.Joins == () {
    try fetchOne(statement.asSelect().count()) ?? 0
  }

  /// Fetches every value produced by raw SQL.
  ///
  /// ```swift
  /// let titles = try transaction.fetchAll(
  ///   #sql("SELECT title FROM reminders ORDER BY id", as: String.self)
  /// )
  /// ```
  ///
  /// - Parameter statement: The SQL to run, which the caller is stating only reads.
  /// - Returns: Every decoded value, in the order the statement produced it.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
  public borrowing func fetchAll<QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<QueryValue>
  ) throws -> [QueryValue.QueryOutput] {
    try fetchCursor(statement, cached: true).collect()
  }

  /// Fetches the first value produced by raw SQL.
  ///
  /// ```swift
  /// let count = try transaction.fetchOne(#sql("SELECT count(*) FROM reminders", as: Int.self))
  /// ```
  ///
  /// - Parameter statement: The SQL to run, which the caller is stating only reads.
  /// - Returns: The first decoded value, or `nil` when the statement produced no row.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
  public borrowing func fetchOne<QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<QueryValue>
  ) throws -> QueryValue.QueryOutput? {
    try fetchCursor(statement, cached: true).first()
  }

  /// Fetches every tuple produced by raw SQL.
  ///
  /// ```swift
  /// let rows = try transaction.fetchAll(
  ///   #sql("SELECT id, title FROM reminders", as: (Int, String).self)
  /// )
  /// ```
  ///
  /// - Parameter statement: The SQL to run, which the caller is stating only reads.
  /// - Returns: Every decoded tuple, in the order the statement produced it.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<each QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each QueryValue)>
  ) throws -> [(repeat (each QueryValue).QueryOutput)] {
    var cursor = try rowCursor(statement, cached: true)
    return try cursor.collectTuples((repeat each QueryValue).self)
  }

  /// Fetches the first tuple produced by raw SQL.
  ///
  /// - Parameter statement: The SQL to run, which the caller is stating only reads.
  /// - Returns: The first decoded tuple, or `nil` when the statement produced no row.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<each QueryValue: QueryRepresentable>(
    _ statement: SQLQueryExpression<(repeat each QueryValue)>
  ) throws -> (repeat (each QueryValue).QueryOutput)? {
    var cursor = try rowCursor(statement, cached: true)
    return try cursor.firstTuple((repeat each QueryValue).self)
  }

  /// Fetches the row with the given primary key.
  ///
  /// ```swift
  /// let reminder = try transaction.find(Reminder.all, key: 42)
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to narrow, typically `Table.all`.
  ///   - primaryKey: The key to look up.
  /// - Returns: The row with that key.
  /// - Throws: ``OrbitDatabaseRecordNotFoundError`` if no row has that primary key, or a
  ///   ``SQLiteError`` when the statement fails.
  public borrowing func find<S: SelectStatement>(
    _ statement: S,
    key primaryKey: some QueryExpression<S.From.PrimaryKey>
  ) throws -> S.From.QueryOutput
  where S.QueryValue == (), S.Joins == (), S.From: PrimaryKeyedTable {
    guard let record = try fetchOne(statement.asSelect().find(primaryKey)) else {
      throw OrbitDatabaseRecordNotFoundError()
    }
    return record
  }
}

// MARK: - Statements that return rows from a write

extension OrbitDatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor that lazily decodes each value returned by a write statement, such as one
  /// with a `RETURNING` clause.
  ///
  /// ```swift
  /// var cursor = try transaction.executeCursor(
  ///   Reminder.insert { Reminder(id: 1, title: "Get milk") }.returning(\.id)
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the decoded values the statement returned.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func executeCursor<QueryValue: QueryRepresentable>(
    _ statement: some Statement<QueryValue>,
    cached: Bool = false
  ) throws -> OrbitDatabaseQueryCursor<RowCursor, QueryValue> {
    OrbitDatabaseQueryCursor(base: try executeRowCursor(statement, cached: cached))
  }

  /// Creates a cursor that lazily decodes each tuple returned by a write statement.
  ///
  /// ```swift
  /// var cursor = try transaction.executeCursor(
  ///   Reminder.insert { Reminder(id: 1, title: "Get milk") }
  ///     .returning { ($0.id, $0.title) }
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - statement: The statement to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the decoded tuples the statement returned.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_lifetime(borrow self)
  public borrowing func executeCursor<each QueryValue: QueryRepresentable>(
    _ statement: some Statement<(repeat each QueryValue)>,
    cached: Bool = false
  ) throws -> OrbitDatabaseTupleQueryCursor<RowCursor, repeat each QueryValue> {
    OrbitDatabaseTupleQueryCursor(base: try executeRowCursor(statement, cached: cached))
  }

  /// Fetches every value returned by a write statement.
  ///
  /// ```swift
  /// let ids = try transaction.fetchAll(
  ///   Reminder.insert { Reminder(id: 1, title: "Get milk") }.returning(\.id)
  /// )
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: Every decoded value the statement returned.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
  public borrowing func fetchAll<QueryValue: QueryRepresentable>(
    _ statement: some Statement<QueryValue>
  ) throws -> [QueryValue.QueryOutput] {
    try executeCursor(statement, cached: true).collect()
  }

  /// Fetches the first value returned by a write statement.
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: The first decoded value, or `nil` when the statement returned no row.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
  public borrowing func fetchOne<QueryValue: QueryRepresentable>(
    _ statement: some Statement<QueryValue>
  ) throws -> QueryValue.QueryOutput? {
    try executeCursor(statement, cached: true).first()
  }

  /// Fetches every tuple returned by a write statement.
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: Every decoded tuple the statement returned.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchAll<each QueryValue: QueryRepresentable>(
    _ statement: some Statement<(repeat each QueryValue)>
  ) throws -> [(repeat (each QueryValue).QueryOutput)] {
    var cursor = try executeRowCursor(statement, cached: true)
    return try cursor.collectTuples((repeat each QueryValue).self)
  }

  /// Fetches the first tuple returned by a write statement.
  ///
  /// - Parameter statement: The statement to run.
  /// - Returns: The first decoded tuple, or `nil` when the statement returned no row.
  /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public borrowing func fetchOne<each QueryValue: QueryRepresentable>(
    _ statement: some Statement<(repeat each QueryValue)>
  ) throws -> (repeat (each QueryValue).QueryOutput)? {
    var cursor = try executeRowCursor(statement, cached: true)
    return try cursor.firstTuple((repeat each QueryValue).self)
  }
}
