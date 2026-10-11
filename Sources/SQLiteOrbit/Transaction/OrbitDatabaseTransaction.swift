/// Controls iteration over the rows returned by a query.
///
/// Returned from the body of ``OrbitDatabaseWriteTransaction/execute(_:_:)`` or
/// ``OrbitDatabaseRowCursor/forEach(_:)`` to say whether the next row should be read.
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
/// Everything a read transaction runs only reads. ``rowCursor(_:cached:)``, and the `fetch`
/// operations built on it, refuse a statement that SQLite reports may write, in a write transaction
/// as much as in a read one. What may write is spelled `execute` and lives on
/// ``OrbitDatabaseWriteTransaction``.
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

  /// Creates a raw row cursor over the rows SQL that only reads returns.
  ///
  /// The statement is checked when it is prepared, and one that SQLite reports may write is
  /// refused rather than run. That holds for every transaction and connection, including a write
  /// transaction, whose ``OrbitDatabaseWriteTransaction/executeRowCursor(_:cached:)`` is the cursor
  /// over SQL that may write.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var cursor = try transaction.rowCursor("SELECT title FROM reminders", cached: true)
  ///   let titles = try cursor.collect(as: String.self)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run, which must only read.
  ///   - cached: Whether the driver may reuse an idle prepared statement for this SQL. Caching is
  ///     an optimization; each live cursor retains independent iteration state. Native SQLite
  ///     drivers prepare another statement when an existing cursor is still using the same SQL.
  /// - Returns: A cursor over the statement's rows, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or one with the
  ///   code ``SQLiteResultCode/readOnly`` when SQLite reports that it may write.
  @_lifetime(borrow self)
  borrowing func rowCursor(_ sql: SQL, cached: Bool) throws -> RowCursor
}

/// The low-level operations available inside a write transaction.
///
/// A write transaction can do everything a read transaction can, and run SQL that writes besides.
/// The read operations it inherits still only read: SQL that may write, including a statement
/// with a `RETURNING` clause, goes through ``execute(_:)``, ``execute(_:_:)``, or
/// ``executeRowCursor(_:cached:)``.
///
/// ```swift
/// try await database.write { transaction in
///   try transaction.execute("INSERT INTO reminders (id, title) VALUES (1, \("Get milk"))")
///   try transaction.execute("UPDATE reminders SET is_completed = \(true) WHERE id = 1")
/// }
/// ```
public protocol OrbitDatabaseWriteTransaction: OrbitDatabaseReadTransaction, ~Copyable, ~Escapable {
  /// Creates a raw row cursor over the rows SQL that may write returns, such as from a
  /// `RETURNING` clause.
  ///
  /// SQLite makes every change a `RETURNING` statement reports on its first step, so the rows the
  /// cursor leaves unread are written all the same.
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   var cursor = try transaction.executeRowCursor(
  ///     "DELETE FROM reminders WHERE is_completed RETURNING id",
  ///     cached: false
  ///   )
  ///   let ids = try cursor.collect(as: Int.self)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - cached: Whether the driver may reuse a prepared statement. See
  ///     ``OrbitDatabaseReadTransaction/rowCursor(_:cached:)``.
  /// - Returns: A cursor over the statement's rows, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  borrowing func executeRowCursor(_ sql: SQL, cached: Bool) throws -> RowCursor

  /// Runs SQL that may write, discarding any rows it returns.
  ///
  /// Interpolated values are bound as parameters rather than spliced into the text. Read
  /// ``changesCount`` afterwards for how many rows it changed.
  ///
  /// ```swift
  /// try transaction.execute("UPDATE reminders SET is_completed = \(true) WHERE id = \(id)")
  /// ```
  ///
  /// - Parameter sql: The SQL to run. Any rows it returns are discarded.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  borrowing func execute(_ sql: SQL) throws

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
}

extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor over the rows SQL that only reads returns, without reusing a prepared
  /// statement.
  ///
  /// A statement that SQLite reports may write is refused with a ``SQLiteError`` whose code is
  /// ``SQLiteResultCode/readOnly``, in a write transaction as much as in a read one.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var cursor = try transaction.rowCursor("SELECT title FROM reminders WHERE list_id = \(id)")
  ///   try cursor.forEach { print($0[0].textValue ?? "") }
  /// }
  /// ```
  ///
  /// - Parameter sql: The SQL to run, which must only read.
  /// - Returns: A cursor over the statement's rows, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write.
  @_lifetime(borrow self)
  public borrowing func rowCursor(_ sql: SQL) throws -> RowCursor {
    try rowCursor(sql, cached: false)
  }

  /// Returns a value made from each row SQL that only reads returns.
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
    try withOrbitCursor(try rowCursor(sql, cached: true)) { try $0.collect(transform) }
  }

  /// Returns a value made from the first row SQL that only reads returns, or `nil` when it
  /// returns none.
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
    try withOrbitCursor(try rowCursor(sql, cached: true)) { try $0.first(transform) }
  }
}

extension OrbitDatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Creates a cursor over the rows SQL that may write returns, such as from a `RETURNING`
  /// clause, without reusing a prepared statement.
  ///
  /// ```swift
  /// var cursor = try transaction.executeRowCursor(
  ///   "DELETE FROM reminders WHERE is_completed RETURNING id"
  /// )
  /// let ids = try cursor.collect(as: Int.self)
  /// ```
  ///
  /// - Parameter sql: The SQL to run.
  /// - Returns: A cursor over the rows the statement returned, valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func executeRowCursor(_ sql: SQL) throws -> RowCursor {
    try executeRowCursor(sql, cached: false)
  }

  /// Runs SQL that may write and lends any returned rows to `body`.
  ///
  /// Rows are lent one at a time and `body` decides whether to read the next, so a `RETURNING`
  /// clause can be consumed without collecting it. SQLite makes every change a `RETURNING`
  /// statement reports on its first step, so stopping early leaves nothing unwritten.
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
    try withOrbitCursor(try executeRowCursor(sql, cached: false)) { try $0.forEach(body) }
  }
}

// MARK: - Cursor terminals

extension OrbitDatabaseRowCursor where Self: ~Copyable, Self: ~Escapable {
  /// Returns a value made from each remaining row, consuming the cursor's rows.
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   var cursor = try transaction.executeRowCursor(
  ///     "UPDATE reminders SET is_completed = 1 RETURNING id, title"
  ///   )
  ///   let completed = try cursor.collect { row in
  ///     (try row[0, as: Int.self], try row[1, as: String.self])
  ///   }
  /// }
  /// ```
  ///
  /// - Parameter transform: Makes a value from a row. The row is only valid for the call.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails.
  @inlinable
  @_lifetime(self: copy self)
  public mutating func collect<Element>(
    _ transform: (inout Row) throws -> Element
  ) throws -> [Element] {
    var elements: [Element] = []
    try forEach { row in elements.append(try transform(&row)) }
    return elements
  }

  /// Returns a value made from the next row, or `nil` when there are no more.
  ///
  /// Only one row is read, and the rest are left unread.
  ///
  /// ```swift
  /// var cursor = try transaction.executeRowCursor(
  ///   "INSERT INTO reminders (title) VALUES (\("Get milk")) RETURNING id"
  /// )
  /// let id = try cursor.first { $0[0].integerValue }
  /// ```
  ///
  /// - Parameter transform: Makes a value from the row. The row is only valid for the call.
  /// - Returns: The value, or `nil` when the cursor had no more rows.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails.
  @inlinable
  @_lifetime(self: copy self)
  public mutating func first<Element>(
    _ transform: (inout Row) throws -> Element
  ) throws -> Element? {
    guard var row = try next() else { return nil }
    return try transform(&row)
  }

  /// Lends each remaining row to `body` until it says to stop or the rows run out.
  ///
  /// ```swift
  /// var cursor = try transaction.rowCursor("SELECT title FROM reminders ORDER BY title")
  /// try cursor.forEach { row in
  ///   print(row[0].textValue ?? "")
  ///   return row[0].textValue == "Get milk" ? .stop : .next
  /// }
  /// ```
  ///
  /// - Parameter body: Receives each row and says whether to read the next. The row is only valid
  ///   for the call.
  /// - Throws: Whatever `body` throws, or a ``SQLiteError`` when the statement fails.
  @inlinable
  @_lifetime(self: copy self)
  public mutating func forEach(
    _ body: (inout Row) throws -> OrbitDatabaseRowIteration
  ) throws {
    while var row = try next() {
      if try body(&row) == .stop { return }
    }
  }

  /// Returns a value initialized from each remaining row.
  ///
  /// A type that is ``ConvertibleFromOrbitDatabaseValue`` reads the first column, and any other
  /// ``ConvertibleFromOrbitDatabaseRow`` type reads the row through its own initializer.
  ///
  /// ```swift
  /// var cursor = try transaction.executeRowCursor(
  ///   "DELETE FROM reminders WHERE isCompleted RETURNING id"
  /// )
  /// let ids = try cursor.collect(as: Int.self)
  /// ```
  ///
  /// - Parameter type: The type to initialize from each row. Make a value type optional to read
  ///   `NULL`.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever the type's initializer throws, such as
  ///   ``OrbitDatabaseColumnDecodingError``, or a ``SQLiteError`` when the statement fails.
  @inlinable
  @_lifetime(self: copy self)
  public mutating func collect<Value: ConvertibleFromOrbitDatabaseRow>(
    as type: Value.Type
  ) throws -> [Value] {
    try collect { row in try Value(orbitDatabaseRow: row) }
  }

  /// Returns a value initialized from the next row, or `nil` when there are no more.
  ///
  /// ```swift
  /// var cursor = try transaction.executeRowCursor(
  ///   "INSERT INTO reminders (title) VALUES (\("Get milk")) RETURNING id"
  /// )
  /// let id = try cursor.first(as: Int.self)
  /// ```
  ///
  /// - Parameter type: The type to initialize from the row.
  /// - Returns: The value, or `nil` when the cursor had no more rows.
  /// - Throws: Whatever the type's initializer throws, such as
  ///   ``OrbitDatabaseColumnDecodingError``, or a ``SQLiteError`` when the statement fails.
  @inlinable
  @_lifetime(self: copy self)
  public mutating func first<Value: ConvertibleFromOrbitDatabaseRow>(
    as type: Value.Type
  ) throws -> Value? {
    try first { row in try Value(orbitDatabaseRow: row) }
  }
}

/// Thrown when a fetch requires a row but the query produces none.
public struct OrbitDatabaseRecordNotFoundError: Error, Sendable {
  /// Creates the error.
  public init() {}
}
