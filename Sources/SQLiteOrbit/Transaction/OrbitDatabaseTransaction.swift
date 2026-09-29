#if StructuredQueries
  public import StructuredQueriesSQLite
#endif

/// Controls iteration over the rows returned by a query.
///
/// Returned from the body of ``OrbitDatabaseWriteTransaction/execute(_:_:)`` to say whether the
/// next row should be read.
///
/// ```swift
/// try await database.write { transaction in
///   try transaction.execute(
///     "INSERT INTO reminders (title) VALUES (\("Get milk")) RETURNING id"
///   ) { row in
///     print(row[0].integerValue ?? 0)
///     return .stop
///   }
/// }
/// ```
public enum OrbitDatabaseRowIteration: Sendable {
  /// Read the next row.
  case next
  /// Stop reading, leaving any remaining rows unread.
  case stop
}

/// The low-level operations available inside a read transaction.
///
/// Transactions are noncopyable and nonescapable so a database can safely lend a connection whose
/// lifetime is bounded by an ``OrbitDatabaseReader/read(_:)`` or ``OrbitDatabaseWriter/write(_:)``
/// call. The `fetch` family is built on the one requirement below, so a conformance only has to
/// know how to lend a cursor.
///
/// ```swift
/// let pending = try await database.read { transaction in
///   try transaction.fetchAll("SELECT title FROM reminders WHERE NOT is_completed") { row in
///     row[0].textValue ?? ""
///   }
/// }
/// ```
public protocol OrbitDatabaseReadTransaction: ~Copyable, ~Escapable {
  /// The row this transaction's cursors lend.
  associatedtype Row: ~Copyable, ~Escapable, OrbitDatabaseRow

  /// The cursor this transaction lends.
  associatedtype RowCursor: ~Copyable, ~Escapable, OrbitDatabaseRowCursor where RowCursor.Row == Row

  /// Creates a raw row cursor over the rows returned by a read query.
  ///
  /// - Parameters:
  ///   - query: A query that has been shown to only read.
  ///   - cached: Whether the driver may reuse a prepared statement it has already compiled for
  ///     this SQL. A cached statement is shared by every cursor over the same SQL on the same
  ///     connection, so only pass `true` when the cursor is fully consumed and discarded before
  ///     any other cursor over that SQL is created.
  /// - Returns: A cursor over the statement's rows, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound. A read
  ///   transaction refuses a statement that SQLite reports may write with the code
  ///   ``SQLiteResultCode/readOnly``, while a write transaction runs it.
  @_lifetime(borrow self)
  borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseReadAccess>,
    cached: Bool
  ) throws -> RowCursor
}

/// The low-level operations available inside a write transaction.
///
/// Write transactions can perform every read operation in addition to executing mutations.
///
/// ```swift
/// try await database.write { transaction in
///   try transaction.execute("INSERT INTO reminders (id, title) VALUES (1, \("Get milk"))")
///   try transaction.execute("UPDATE reminders SET is_completed = \(true) WHERE id = 1")
/// }
/// ```
public protocol OrbitDatabaseWriteTransaction: OrbitDatabaseReadTransaction, ~Copyable, ~Escapable {
  /// Creates a raw row cursor over the rows returned by a write query, such as one with a
  /// `RETURNING` clause.
  ///
  /// - Parameters:
  ///   - query: A query to run.
  ///   - cached: Whether the driver may reuse a prepared statement. See
  ///     ``OrbitDatabaseReadTransaction/rowCursor(_:cached:)``.
  /// - Returns: A cursor over the statement's rows, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseWriteAccess>,
    cached: Bool
  ) throws -> RowCursor

  /// How many rows the most recent statement on this connection inserted, updated, or deleted.
  ///
  /// This is `sqlite3_changes64`, which counts the last statement rather than the transaction, so
  /// reading it after a second ``execute(_:)`` reports only what that second statement changed. A
  /// statement that changes nothing, such as a `SELECT` or a `CREATE TABLE`, leaves the previous
  /// count in place rather than resetting it to zero.
  ///
  /// ```swift
  /// let deleted = try await database.write { transaction in
  ///   try transaction.execute("DELETE FROM reminders WHERE is_completed")
  ///   return transaction.changesCount
  /// }
  /// ```
  ///
  /// - Important: The count belongs to the connection, not to this transaction, and the next
  ///   access may be lent a different connection. Read it inside the same access as the write it
  ///   describes.
  var changesCount: Int { get }

  /// The rowid of the most recent successful insert on this connection.
  ///
  /// This is `sqlite3_last_insert_rowid`, which is how a table with an `INTEGER PRIMARY KEY`
  /// SQLite filled in reports what it chose. A statement that inserts nothing leaves the previous
  /// rowid in place, and a connection that has never inserted reports `0`.
  ///
  /// ```swift
  /// let id = try await database.write { transaction in
  ///   try transaction.execute("INSERT INTO reminders (title) VALUES (\("Get milk"))")
  ///   return transaction.lastInsertedRowID
  /// }
  /// ```
  ///
  /// - Important: The rowid belongs to the connection, not to this transaction, and the next
  ///   access may be lent a different connection. Read it inside the same access as the insert it
  ///   describes.
  var lastInsertedRowID: Int64 { get }

  /// Runs a query, discarding any rows it returns.
  ///
  /// Read ``changesCount`` afterwards for how many rows it changed.
  ///
  /// - Parameter query: The query to run. Any rows it returns are discarded.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  borrowing func execute(_ query: OrbitDatabaseQuery<OrbitDatabaseWriteAccess>) throws
}

extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor over the rows raw SQL returns.
  ///
  /// In a read transaction the SQL must only read: a driver refuses a statement that SQLite
  /// reports may write with a ``SQLiteError`` whose code is ``SQLiteResultCode/readOnly``. A write
  /// transaction runs it as it is.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var cursor = try transaction.rowCursor("SELECT title FROM reminders WHERE list_id = \(id)")
  ///   try cursor.forEach { print($0[0].textValue ?? "") }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL. See
  ///     ``OrbitDatabaseReadTransaction/rowCursor(_:cached:)``.
  /// - Returns: A cursor over the statement's rows, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write in
  ///   a read transaction.
  @_lifetime(borrow self)
  public borrowing func rowCursor(_ sql: SQL, cached: Bool = false) throws -> RowCursor {
    try rowCursor(OrbitDatabaseQuery<OrbitDatabaseReadAccess>(sql), cached: cached)
  }

  /// Returns a value made from each row raw SQL returns.
  ///
  /// ```swift
  /// let titles = try await database.read { transaction in
  ///   try transaction.fetchAll("SELECT title FROM reminders ORDER BY title") { row in
  ///     row[0].textValue ?? ""
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run, which must only read in a read transaction.
  ///   - transform: Makes a value from a row. The row is only valid for the call.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails or may
  ///   write in a read transaction.
  public borrowing func fetchAll<Element>(
    _ sql: SQL,
    _ transform: (inout Row) throws -> Element
  ) throws -> [Element] {
    try withOrbitCursor(try rowCursor(sql, cached: true)) { try $0.collect(transform) }
  }

  /// Returns a value made from the first row raw SQL returns, or `nil` when it returns none.
  ///
  /// Only the first row is read.
  ///
  /// ```swift
  /// let count = try await database.read { transaction in
  ///   try transaction.fetchOne("SELECT count(*) FROM reminders") { $0[0].integerValue }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run, which must only read in a read transaction.
  ///   - transform: Makes a value from the row. The row is only valid for the call.
  /// - Returns: The value, or `nil` when the SQL returned no rows.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails or may
  ///   write in a read transaction.
  public borrowing func fetchOne<Element>(
    _ sql: SQL,
    _ transform: (inout Row) throws -> Element
  ) throws -> Element? {
    try withOrbitCursor(try rowCursor(sql, cached: true)) { try $0.first(transform) }
  }
}

extension OrbitDatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Runs raw SQL, discarding any rows it returns.
  ///
  /// Interpolated values are bound as parameters rather than spliced into the text. Read
  /// ``changesCount`` afterwards for how many rows it changed.
  ///
  /// ```swift
  /// try transaction.execute("UPDATE reminders SET is_completed = \(true) WHERE id = \(id)")
  /// ```
  ///
  /// - Parameter sql: The SQL to run.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  public borrowing func execute(_ sql: SQL) throws {
    try execute(OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(sql))
  }

  /// Runs raw SQL and lends any returned rows to `body`.
  ///
  /// Rows are lent one at a time and `body` decides whether to read the next, so a `RETURNING`
  /// clause can be consumed without collecting it.
  ///
  /// ```swift
  /// try transaction.execute(
  ///   "INSERT INTO reminders (title) VALUES (\("Get milk")) RETURNING id"
  /// ) { row in
  ///   print(row[0].integerValue ?? 0)
  ///   return .next
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - body: Receives each returned row and says whether to read the next.
  /// - Throws: Whatever `body` throws, or a ``SQLiteError`` when the statement fails.
  public borrowing func execute(
    _ sql: SQL,
    _ body: (inout Row) throws -> OrbitDatabaseRowIteration
  ) throws {
    try withOrbitCursor(try executeRowCursor(sql)) { try $0.forEach(body) }
  }

  /// Creates a cursor over the rows raw SQL that may write returns, such as from a `RETURNING`
  /// clause.
  ///
  /// ```swift
  /// var cursor = try transaction.executeRowCursor(
  ///   "DELETE FROM reminders WHERE is_completed RETURNING id"
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
  /// - Returns: A cursor over the rows the statement returned.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func executeRowCursor(_ sql: SQL, cached: Bool = false) throws -> RowCursor {
    try rowCursor(OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(sql), cached: cached)
  }

  /// Returns a value made from each row raw SQL returns, where the SQL may write.
  ///
  /// This is the write transaction's counterpart to the read-only
  /// ``OrbitDatabaseReadTransaction/fetchAll(_:_:)``, so a `RETURNING` clause can be collected.
  ///
  /// ```swift
  /// let ids = try await database.write { transaction in
  ///   try transaction.fetchAll("DELETE FROM reminders WHERE is_completed RETURNING id") { row in
  ///     row[0].integerValue ?? 0
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - transform: Makes a value from a row. The row is only valid for the call.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails.
  public borrowing func fetchAll<Element>(
    _ sql: SQL,
    _ transform: (inout Row) throws -> Element
  ) throws -> [Element] {
    try withOrbitCursor(try executeRowCursor(sql, cached: true)) { try $0.collect(transform) }
  }

  /// Returns a value made from the first row raw SQL returns, where the SQL may write.
  ///
  /// Only the first row is read. SQLite makes every change a `RETURNING` statement reports on
  /// its first step, so the rows left unread are written all the same.
  ///
  /// ```swift
  /// let id = try await database.write { transaction in
  ///   try transaction.fetchOne(
  ///     "INSERT INTO reminders (title) VALUES (\("Get milk")) RETURNING id"
  ///   ) { $0[0].integerValue }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - transform: Makes a value from the first row. The row is only valid for the call.
  /// - Returns: The value, or `nil` when the SQL returned no rows.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails.
  public borrowing func fetchOne<Element>(
    _ sql: SQL,
    _ transform: (inout Row) throws -> Element
  ) throws -> Element? {
    try withOrbitCursor(try executeRowCursor(sql, cached: true)) { try $0.first(transform) }
  }
}

// The loops behind the raw fetches and `execute(_:_:)`, which consume their cursor before
// returning, so each lends its rows the same way.
extension OrbitDatabaseRowCursor where Self: ~Copyable, Self: ~Escapable {
  @_lifetime(self: copy self)
  mutating func collect<Element>(_ transform: (inout Row) throws -> Element) throws -> [Element] {
    var elements: [Element] = []
    try forEach { row in elements.append(try transform(&row)) }
    return elements
  }

  @_lifetime(self: copy self)
  mutating func first<Element>(_ transform: (inout Row) throws -> Element) throws -> Element? {
    guard var row = try next() else { return nil }
    return try transform(&row)
  }

  // Lends each row to `body` until it says to stop or the rows run out.
  @_lifetime(self: copy self)
  mutating func forEach(_ body: (inout Row) throws -> OrbitDatabaseRowIteration) throws {
    while var row = try next() {
      if try body(&row) == .stop { return }
    }
  }
}

// MARK: - Structured Queries

#if StructuredQueries
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

  // MARK: - Undecoded rows

  extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
    /// Creates a raw row cursor over the rows returned by a `SELECT`-shaped statement.
    ///
    /// Rows are lent undecoded, which is the escape hatch for reading columns the query builder
    /// does not describe. ``OrbitDatabaseReadTransaction/fetchCursor(_:cached:)`` is the typed
    /// equivalent.
    ///
    /// ```swift
    /// try await database.read { transaction in
    ///   var cursor = try transaction.rowCursor(Reminder.select(\.title))
    ///   try cursor.forEach { print($0[0].textValue ?? "") }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - statement: A statement that only reads.
    ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
    /// - Returns: A cursor over the statement's rows.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_lifetime(borrow self)
    public borrowing func rowCursor(
      _ statement: some PartialSelectStatement,
      cached: Bool = false
    ) throws -> RowCursor {
      try rowCursor(OrbitDatabaseQuery<OrbitDatabaseReadAccess>(statement), cached: cached)
    }

    /// Creates a raw row cursor over the rows returned by raw SQL.
    ///
    /// The capability of raw SQL cannot be read off its type, so the caller is stating that it
    /// reads.
    ///
    /// ```swift
    /// var cursor = try transaction.rowCursor(#sql("PRAGMA table_info(reminders)", as: Void.self))
    /// ```
    ///
    /// - Parameters:
    ///   - statement: The SQL to run.
    ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
    /// - Returns: A cursor over the statement's rows.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_lifetime(borrow self)
    public borrowing func rowCursor<QueryValue>(
      _ statement: SQLQueryExpression<QueryValue>,
      cached: Bool = false
    ) throws -> RowCursor {
      try rowCursor(OrbitDatabaseQuery<OrbitDatabaseReadAccess>(statement), cached: cached)
    }
  }

  extension OrbitDatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
    /// Creates a raw row cursor over the rows returned by a write statement.
    ///
    /// ```swift
    /// var cursor = try transaction.executeRowCursor(
    ///   Reminder.insert { Reminder(id: 1, title: "Get milk") }.returning(\.id)
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - statement: The statement to run.
    ///   - cached: Whether the driver may reuse a prepared statement for this SQL.
    /// - Returns: A cursor over the rows the statement returned.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_lifetime(borrow self)
    public borrowing func executeRowCursor(
      _ statement: some Statement,
      cached: Bool = false
    ) throws -> RowCursor {
      try rowCursor(OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(statement), cached: cached)
    }

    /// Executes a statement, discarding any rows it returns.
    ///
    /// ```swift
    /// try transaction.execute(Reminder.where(\.isCompleted).delete())
    /// let deleted = transaction.changesCount
    /// ```
    ///
    /// - Parameter statement: The statement to run.
    /// - Throws: A ``SQLiteError`` when the statement fails.
    public borrowing func execute(_ statement: some Statement) throws {
      try execute(OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(statement))
    }

    /// Executes a statement and lends any returned rows to `body`.
    ///
    /// Rows are lent one at a time and `body` decides whether to read the next, so a `RETURNING`
    /// clause can be consumed without collecting it.
    ///
    /// ```swift
    /// try transaction.execute(
    ///   Reminder.insert { Reminder(id: 1, title: "Get milk") }.returning(\.id)
    /// ) { row in
    ///   print(try row.decode(Int.self))
    ///   return .next
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - statement: The statement to run.
    ///   - body: Receives each returned row and says whether to read the next.
    /// - Throws: Whatever `body` throws, or a ``SQLiteError`` when the statement fails.
    public borrowing func execute(
      _ statement: some Statement,
      _ body: (inout Row) throws -> OrbitDatabaseRowIteration
    ) throws {
      try execute(SQL(fragment: statement.query), body)
    }
  }

  // Statements come in four shapes, and each needs its own decoding. A statement either projects a
  // single value, projects a tuple of values, or projects nothing at all, in which case its rows
  // decode to its `FROM` table plus whatever tables are joined to it. Raw SQL takes the first two
  // shapes, but has no type in common with the select statements, so it is spelled out again.
  //
  // These are written once, on the read transaction. `OrbitDatabaseWriteTransaction` refines
  // `OrbitDatabaseReadTransaction`, so write transactions inherit all four.

  // MARK: - Cursors

  extension OrbitDatabaseReadTransaction
  where Self: ~Copyable, Self: ~Escapable, Row: OrbitDatabaseStructuredRow {
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
  extension OrbitDatabaseRowCursor
  where Self: ~Copyable, Self: ~Escapable, Row: OrbitDatabaseStructuredRow {
    @_lifetime(self: copy self)
    mutating func collectTuples<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> [(repeat (each Value).QueryOutput)] {
      var values: [(repeat (each Value).QueryOutput)] = []
      try forEach { row in values.append(try row.decode((repeat each Value).self)) }
      return values
    }

    @_lifetime(self: copy self)
    mutating func firstTuple<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> (repeat (each Value).QueryOutput)? {
      guard var row = try next() else { return nil }
      return try row.decode((repeat each Value).self)
    }
  }

  extension OrbitDatabaseReadTransaction
  where Self: ~Copyable, Self: ~Escapable, Row: OrbitDatabaseStructuredRow {
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
      return try withOrbitCursor(try rowCursor(statement, cached: true)) { cursor in
        try cursor.collectTuples((repeat each QueryValue).self)
      }
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
      return try withOrbitCursor(try rowCursor(statement, cached: true)) { cursor in
        try cursor.firstTuple((repeat each QueryValue).self)
      }
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
      return try withOrbitCursor(try rowCursor(statement, cached: true)) { cursor in
        try cursor.collectTuples((repeat each QueryValue).self)
      }
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
      return try withOrbitCursor(try rowCursor(statement, cached: true)) { cursor in
        try cursor.firstTuple((repeat each QueryValue).self)
      }
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

  extension OrbitDatabaseWriteTransaction
  where Self: ~Copyable, Self: ~Escapable, Row: OrbitDatabaseStructuredRow {
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
      return try withOrbitCursor(try executeRowCursor(statement, cached: true)) { cursor in
        try cursor.collectTuples((repeat each QueryValue).self)
      }
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
      return try withOrbitCursor(try executeRowCursor(statement, cached: true)) { cursor in
        try cursor.firstTuple((repeat each QueryValue).self)
      }
    }
  }
#endif
