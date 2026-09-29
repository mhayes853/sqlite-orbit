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
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound. A driver refuses
  ///   a statement that SQLite reports may write with the code ``SQLiteResultCode/readOnly``.
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
  /// The SQL must only read: a driver refuses a statement that SQLite reports may write with a
  /// ``SQLiteError`` whose code is ``SQLiteResultCode/readOnly``.
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
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write.
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
  ///   - sql: The SQL to run, which must only read.
  ///   - transform: Makes a value from a row. The row is only valid for the call.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails or may
  ///   write.
  public borrowing func fetchAll<Element>(
    _ sql: SQL,
    _ transform: (inout Row) throws -> Element
  ) throws -> [Element] {
    var cursor = try rowCursor(sql)
    var elements: [Element] = []
    while var row = try cursor.next() {
      elements.append(try transform(&row))
    }
    return elements
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
  ///   - sql: The SQL to run, which must only read.
  ///   - transform: Makes a value from the row. The row is only valid for the call.
  /// - Returns: The value, or `nil` when the SQL returned no rows.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails or may
  ///   write.
  public borrowing func fetchOne<Element>(
    _ sql: SQL,
    _ transform: (inout Row) throws -> Element
  ) throws -> Element? {
    var cursor = try rowCursor(sql)
    guard var row = try cursor.next() else { return nil }
    return try transform(&row)
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
    var cursor = try executeRowCursor(sql)
    while var row = try cursor.next() {
      if try body(&row) == .stop { return }
    }
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
    var cursor = try executeRowCursor(sql)
    var elements: [Element] = []
    while var row = try cursor.next() {
      elements.append(try transform(&row))
    }
    return elements
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
    var cursor = try executeRowCursor(sql)
    guard var row = try cursor.next() else { return nil }
    return try transform(&row)
  }
}
