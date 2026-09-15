import StructuredQueries

/// A read transaction lent by a native SQLite driver.
///
/// The transaction is a view onto a connection rather than an owner of one. It is noncopyable and
/// nonescapable, so the connection it borrows cannot be captured, stored, or outlived.
///
/// ```swift
/// let titles = try await database.read { (transaction: borrowing SQLiteReadTransaction) in
///   try transaction.fetchAll(Reminder.select(\.title))
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
  let observations: OrbitDatabaseTransactionObservationContext

  @_lifetime(borrow handle)
  init(
    handle: borrowing SQLiteHandle,
    observations: OrbitDatabaseTransactionObservationContext
  ) {
    self.access = SQLiteConnectionAccess(handle: handle)
    self.statements = handle.statements
    self.authorizer = handle.authorizer
    self.observations = observations
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
  /// change an access makes to the connection's settings, such as its busy timeout.
  public var configuration: SQLiteConfiguration {
    access.configurationPointer.pointee
  }

  var connection: OpaquePointer { access.sqliteConnection }
  var library: UnsafePointer<SQLiteLibrary> { access.libraryPointer }

  /// Creates a cursor over the rows a read query returns.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseReadAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try cursor(for: query.fragment, cached: cached)
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

  borrowing func withObserver<Result: ~Copyable>(
    _ observer: any OrbitDatabaseTransactionObserver,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    try observations.withObserver(observer, perform: operation)
  }

  @_lifetime(borrow self)
  borrowing func cursor(
    for query: QueryFragment,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try SQLiteRowCursor(
      query,
      cached: cached,
      connection: connection,
      library: library,
      statements: statements,
      authorizer: authorizer,
      observations: observations
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
///   try transaction.execute(Reminder.insert { Reminder(id: 1, title: "Get milk") })
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
    handle: borrowing SQLiteHandle,
    observations: OrbitDatabaseTransactionObservationContext
  ) {
    self.base = SQLiteReadTransaction(handle: handle, observations: observations)
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
  /// change an access makes to the connection's settings, such as its busy timeout.
  public var configuration: SQLiteConfiguration {
    base.configuration
  }

  /// Creates a cursor over the rows a read query returns.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseReadAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try base.cursor(for: query.fragment, cached: cached)
  }

  /// Creates a cursor over the rows a write query returns, such as one with a `RETURNING` clause.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseWriteAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try base.cursor(for: query.fragment, cached: cached)
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

  /// Runs a query to completion, discarding any rows it returns.
  ///
  /// A query that builds no SQL runs nothing at all, so it leaves ``changesCount`` reporting
  /// whatever the statement before it changed.
  ///
  /// - Parameter query: The query to run. Any rows it returns are stepped past and discarded.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  public borrowing func execute(_ query: OrbitDatabaseQuery<OrbitDatabaseWriteAccess>) throws {
    guard !query.fragment.isEmpty else { return }
    var cursor = try base.cursor(for: query.fragment, cached: false)
    while try cursor.next() != nil {}
  }

  /// Runs SQL that the query builder does not model, such as schema changes.
  ///
  /// Several statements may be given at once, separated by semicolons, and any rows they produce
  /// are discarded.
  ///
  /// ```swift
  /// try transaction.execute(
  ///   "CREATE TABLE reminders (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
  /// )
  /// ```
  ///
  /// - Parameter sql: One or more statements.
  /// - Throws: A ``SQLiteError`` naming the SQL that failed.
  public borrowing func execute(_ sql: String) throws {
    try SQLiteHandle.execute(
      sql,
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
}
