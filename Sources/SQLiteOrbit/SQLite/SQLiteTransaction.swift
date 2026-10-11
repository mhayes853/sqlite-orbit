/// A transaction or connection lent by a native SQLite driver.
///
/// ``SQLiteReadTransaction``, ``SQLiteWriteTransaction``, ``SQLiteReadConnection``, and
/// ``SQLiteWriteConnection`` all conform, so code that needs what lies beneath them — the raw
/// connection, the SQLite build it runs against, or the configuration it was opened with — is
/// written once for every one of them. Everything ``OrbitDatabaseReadTransaction`` reads is
/// available as well, since this refines it.
///
/// ```swift
/// func isEncrypted<Transaction>(_ transaction: borrowing Transaction) -> Bool
/// where Transaction: SQLiteTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
///   transaction.configuration.key != nil
/// }
///
/// let encrypted = try await database.read { isEncrypted($0) }
/// ```
public protocol SQLiteTransaction: OrbitDatabaseReadTransaction, ~Copyable, ~Escapable {
  /// The underlying `sqlite3 *`.
  ///
  /// This is the escape hatch for work the package does not model. It is only valid for the
  /// duration of the access that lent the transaction or connection.
  var sqliteConnection: OpaquePointer { get }

  /// The SQLite build the connection runs against, so raw work uses the same one.
  var sqlite: SQLiteLibrary { get }

  /// The configuration the connection was opened with.
  ///
  /// This is the configuration the driver was given. What a driver adds for a connection's role,
  /// such as the `PRAGMA query_only` a pool's readers run, is not part of it, and neither is a
  /// change an access makes to the connection's settings, such as its busy policy.
  var configuration: SQLiteConfiguration { get }
}

/// A read transaction lent by a native SQLite driver.
///
/// The transaction is a view onto a connection rather than an owner of one. It is noncopyable and
/// nonescapable, so the connection it borrows cannot be captured, stored, or outlived.
///
/// ```swift
/// let titles = try await database.read { (transaction: borrowing SQLiteReadTransaction) in
///   try transaction.fetchAll("SELECT title FROM reminders") { $0[0].textValue }
/// }
/// ```
public struct SQLiteReadTransaction: SQLiteTransaction, ~Copyable, ~Escapable {
  /// The row this transaction's cursors lend.
  public typealias Row = SQLiteRow

  /// The cursor this transaction lends.
  public typealias RowCursor = SQLiteRowCursor

  let access: SQLiteConnectionAccess
  let statements: SQLiteStatementCache
  let authorizer: SQLiteAuthorizerDispatcher
  let observations: SQLiteConnectionEvents
  let connectionState: SQLiteConnectionState?

  @_lifetime(borrow handle)
  init(
    handle: borrowing SQLiteConnection,
    observations: SQLiteConnectionEvents,
    connectionState: SQLiteConnectionState? = nil
  ) {
    self.access = SQLiteConnectionAccess(handle: handle)
    self.statements = handle.statements
    self.authorizer = handle.authorizer
    self.observations = observations
    self.connectionState = connectionState
  }

  /// The underlying `sqlite3 *`.
  ///
  /// This is the escape hatch for work the package does not model. It is only valid for the
  /// duration of the access that lent this transaction and must not be used to mutate the database.
  public var sqliteConnection: OpaquePointer {
    access.sqliteConnection
  }

  /// The SQLite build this connection runs against, so raw work uses the same one.
  public var sqlite: SQLiteLibrary {
    access.sqlite
  }

  /// The configuration the connection was opened with.
  ///
  /// This is the configuration the driver was given. What a driver adds for a connection's role,
  /// such as the `PRAGMA query_only` a pool's readers run, is not part of it, and neither is a
  /// change an access makes to the connection's settings, such as its busy policy.
  public var configuration: SQLiteConfiguration {
    access.configurationPointer.pointee
  }

  var connection: OpaquePointer { access.sqliteConnection }
  var library: UnsafePointer<SQLiteLibrary> { access.libraryPointer }

  /// Creates a cursor over the rows SQL that only reads returns.
  ///
  /// The SQL is refused with ``SQLiteResultCode/readOnly`` when SQLite reports that it may write.
  ///
  /// ```swift
  /// var cursor = try transaction.rowCursor("SELECT title FROM reminders", cached: true)
  /// let titles = try cursor.collect(as: String.self)
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run, which must only read.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or one with the
  ///   code ``SQLiteResultCode/readOnly`` when SQLite reports that it may write.
  @_lifetime(borrow self)
  public borrowing func rowCursor(_ sql: SQL, cached: Bool) throws -> SQLiteRowCursor {
    try cursor(for: sql, cached: cached, requiresReadOnly: true)
  }

  /// Creates a cursor over the rows SQL that only reads returns, without reusing a prepared
  /// statement.
  ///
  /// The SQL is refused with ``SQLiteResultCode/readOnly`` when SQLite reports that it may write.
  ///
  /// ```swift
  /// var cursor = try transaction.rowCursor("SELECT title FROM reminders")
  /// ```
  ///
  /// - Parameter sql: The SQL to run, which must only read.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write.
  @_lifetime(borrow self)
  public borrowing func rowCursor(_ sql: SQL) throws -> SQLiteRowCursor {
    // Spelled out on the concrete type, rather than left to the protocol extension, because
    // Swift 6.3 tears down a failed cursor as garbage when a caller binds one a generic function
    // returned.
    try cursor(for: sql, cached: false, requiresReadOnly: true)
  }

  /// Notifies transaction observers that this transaction may have read a database region.
  ///
  /// Use this after a read performed through ``sqliteConnection`` or another API that SQLiteOrbit
  /// cannot track.
  ///
  /// - Parameter region: The region the transaction may have read.
  public borrowing func notifyReads(in region: OrbitDatabaseRegion) {
    observations.didRead(in: region)
  }

  /// Observes only the connection events produced while `operation` runs.
  ///
  /// Registrations nest in call order and never observe another connection's access. A scoped
  /// observer receives a commit or rollback only if it remains registered when that event occurs.
  public borrowing func withObservation<Result: ~Copyable>(
    _ observer: any OrbitDatabaseTransactionObserver,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    try observations.withObservation(observer, perform: operation)
  }

  @_lifetime(borrow self)
  borrowing func cursor(
    for query: SQL,
    cached: Bool,
    requiresReadOnly: Bool
  ) throws -> SQLiteRowCursor {
    try SQLiteRowCursor(
      query,
      cached: cached,
      requiresReadOnly: requiresReadOnly,
      connection: connection,
      library: library,
      statements: statements,
      authorizer: authorizer,
      observations: observations,
      connectionState: connectionState
    )
  }
}

/// A write transaction lent by a native SQLite driver.
///
/// A write transaction is a read transaction that may also mutate, so it wraps one rather than
/// repeating it.
///
/// ```swift
/// try await database.write { (transaction: borrowing SQLiteWriteTransaction) in
///   try transaction.execute("INSERT INTO reminders (id, title) VALUES (1, 'Get milk')")
/// }
/// ```
public struct SQLiteWriteTransaction: OrbitDatabaseWriteTransaction, SQLiteTransaction, ~Copyable,
  ~Escapable
{
  /// The row this transaction's cursors lend.
  public typealias Row = SQLiteRow

  /// The cursor this transaction lends.
  public typealias RowCursor = SQLiteRowCursor

  let base: SQLiteReadTransaction

  @_lifetime(borrow handle)
  init(
    handle: borrowing SQLiteConnection,
    observations: SQLiteConnectionEvents,
    connectionState: SQLiteConnectionState? = nil
  ) {
    self.base = SQLiteReadTransaction(
      handle: handle,
      observations: observations,
      connectionState: connectionState
    )
  }

  /// The underlying `sqlite3 *`.
  public var sqliteConnection: OpaquePointer {
    base.connection
  }

  /// The SQLite build this connection runs against, so raw work uses the same one.
  public var sqlite: SQLiteLibrary {
    base.sqlite
  }

  /// The configuration the connection was opened with.
  ///
  /// This is the configuration the driver was given. What a driver adds for a connection's role,
  /// such as the `PRAGMA query_only` a pool's readers run, is not part of it, and neither is a
  /// change an access makes to the connection's settings, such as its busy policy.
  public var configuration: SQLiteConfiguration {
    base.configuration
  }

  /// Creates a cursor over the rows SQL that only reads returns.
  ///
  /// A write transaction reads the way a read transaction does: SQL that SQLite reports may write
  /// is refused with ``SQLiteResultCode/readOnly``. Run it through ``executeRowCursor(_:cached:)``
  /// instead.
  ///
  /// ```swift
  /// var cursor = try transaction.rowCursor("SELECT title FROM reminders", cached: true)
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run, which must only read.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or one with the
  ///   code ``SQLiteResultCode/readOnly`` when SQLite reports that it may write.
  @_lifetime(borrow self)
  public borrowing func rowCursor(_ sql: SQL, cached: Bool) throws -> SQLiteRowCursor {
    try base.cursor(for: sql, cached: cached, requiresReadOnly: true)
  }

  /// Creates a cursor over the rows SQL that only reads returns, without reusing a prepared
  /// statement.
  ///
  /// SQL that SQLite reports may write is refused with ``SQLiteResultCode/readOnly``.
  ///
  /// ```swift
  /// var cursor = try transaction.rowCursor("SELECT title FROM reminders")
  /// ```
  ///
  /// - Parameter sql: The SQL to run, which must only read.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write.
  @_lifetime(borrow self)
  public borrowing func rowCursor(_ sql: SQL) throws -> SQLiteRowCursor {
    // Spelled out on the concrete type, rather than left to the protocol extension, because
    // Swift 6.3 tears down a failed cursor as garbage when a caller binds one a generic function
    // returned.
    try base.cursor(for: sql, cached: false, requiresReadOnly: true)
  }

  /// Creates a cursor over the rows SQL that may write returns, such as from a `RETURNING`
  /// clause.
  ///
  /// Whatever the statement changes is reported to observers like any other write.
  ///
  /// ```swift
  /// var cursor = try transaction.executeRowCursor(
  ///   "DELETE FROM reminders WHERE is_completed RETURNING id",
  ///   cached: true
  /// )
  /// let ids = try cursor.collect(as: Int.self)
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func executeRowCursor(_ sql: SQL, cached: Bool) throws -> SQLiteRowCursor {
    try base.cursor(for: sql, cached: cached, requiresReadOnly: false)
  }

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
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func executeRowCursor(_ sql: SQL) throws -> SQLiteRowCursor {
    // Spelled out on the concrete type for the same reason as `rowCursor(_:)`.
    try base.cursor(for: sql, cached: false, requiresReadOnly: false)
  }

  /// How many rows the most recent statement on this connection inserted, updated, or deleted.
  ///
  /// See ``OrbitDatabaseWriteTransaction/changesCount``: the count belongs to the connection this
  /// transaction borrows, so read it inside the access that wrote.
  public var changesCount: Int {
    Int(base.library.pointee.connections.changes(base.connection))
  }

  /// The rowid of the most recent successful insert on this connection.
  ///
  /// See ``OrbitDatabaseWriteTransaction/lastInsertedRowID``: the rowid belongs to the connection
  /// this transaction borrows, so read it inside the access that inserted.
  public var lastInsertedRowID: Int64 {
    base.library.pointee.connections.lastInsertedRowID(base.connection)
  }

  /// Runs SQL that may write to completion, discarding any rows it returns.
  ///
  /// Interpolated values are bound as parameters rather than spliced into the text. SQL that
  /// holds no statement, such as an empty string, runs nothing at all, so it leaves
  /// ``changesCount`` reporting whatever the statement before it changed.
  ///
  /// ```swift
  /// try transaction.execute("UPDATE reminders SET is_completed = \(true) WHERE id = \(id)")
  /// let updated = transaction.changesCount
  /// ```
  ///
  /// - Parameter sql: The SQL to run. Any rows it returns are stepped past and discarded.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  public borrowing func execute(_ sql: SQL) throws {
    var cursor = try base.cursor(for: sql, cached: false, requiresReadOnly: false)
    while try cursor.next() != nil {}
  }

  /// Runs a script of one or more statements, such as a schema.
  ///
  /// Statements are separated by semicolons, and any rows they produce are discarded. A script
  /// takes no parameters: its text is run as it is, so build it only from text the program itself
  /// controls, and run a statement with values in it through ``SQL`` instead, which binds them.
  ///
  /// ```swift
  /// try transaction.executeScript(
  ///   """
  ///   CREATE TABLE lists (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
  ///   CREATE TABLE reminders (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists(id));
  ///   """
  /// )
  /// ```
  ///
  /// - Parameter script: One or more statements.
  /// - Throws: A ``SQLiteError`` naming the SQL that failed.
  public borrowing func executeScript(_ script: String) throws {
    try SQLiteConnection.executeScript(
      script,
      on: base.connection,
      library: base.library,
      authorizer: base.authorizer,
      statements: base.statements,
      observations: base.observations
    )
  }

  /// Notifies transaction observers that this transaction may have changed a database region.
  ///
  /// Use this after a successful write performed through ``sqliteConnection`` or another API that
  /// SQLiteOrbit cannot track. The notification remains provisional until the transaction commits.
  ///
  /// - Parameter region: The region the transaction may have changed.
  public borrowing func notifyChanges(in region: OrbitDatabaseRegion) {
    base.observations.didChange(in: region)
  }

  /// Notifies transaction observers that this transaction may have read a database region.
  ///
  /// Use this after a read performed through ``sqliteConnection`` or another API that SQLiteOrbit
  /// cannot track.
  ///
  /// - Parameter region: The region the transaction may have read.
  public borrowing func notifyReads(in region: OrbitDatabaseRegion) {
    base.observations.didRead(in: region)
  }

  /// Observes only the connection events produced while `operation` runs.
  ///
  /// The transaction commits after its access closure returns, so a registration scoped to that
  /// closure observes its provisional changes, but not its later commit or rollback.
  public borrowing func withObservation<Result: ~Copyable>(
    _ observer: any OrbitDatabaseTransactionObserver,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    try base.withObservation(observer, perform: operation)
  }

}
