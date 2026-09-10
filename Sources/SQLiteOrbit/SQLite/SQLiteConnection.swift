public import StructuredQueries

/// A connection lent by a native SQLite driver for reading outside a transaction.
///
/// Each statement runs in its own implicit transaction, so two reads may see different states of
/// the database if another connection commits in between. Call ``transaction(_:)`` for a
/// consistent snapshot. Statements that begin or end a transaction or a savepoint are refused
/// outside ``transaction(_:)``, so the connection always knows whether it is inside one.
///
/// Like a transaction, the connection is a view onto a connection it borrows. It is noncopyable
/// and nonescapable, so it cannot be captured, stored, or outlive the access that lent it.
///
/// ```swift
/// let (mode, count) = try await database.readWithoutTransaction { connection in
///   let mode = try connection.fetchOne(#sql("PRAGMA journal_mode", as: String.self))
///   let count = try connection.transaction { try $0.fetchCount(Reminder.all) }
///   return (mode, count)
/// }
/// ```
public struct SQLiteReadConnection: OrbitDatabaseReadTransaction, ~Copyable, ~Escapable {
  /// The row this connection's cursors lend.
  public typealias Row = SQLiteRow

  /// The cursor this connection lends.
  public typealias RowCursor = SQLiteRowCursor

  // A statement outside a transaction runs through the same view a read transaction lends, and
  // SQLite gives it an implicit transaction of its own.
  let base: SQLiteReadTransaction
  let handle: UnsafePointer<SQLiteHandle>
  let state: SQLiteConnectionState

  @_lifetime(borrow handle)
  init(
    handle: borrowing SQLiteHandle,
    at address: UnsafePointer<SQLiteHandle>,
    observations: OrbitDatabaseTransactionObservationContext,
    state: SQLiteConnectionState
  ) {
    self.base = SQLiteReadTransaction(handle: handle, observations: observations)
    self.handle = address
    self.state = state
  }

  /// The underlying `sqlite3 *`.
  ///
  /// This is the escape hatch for work the package does not model. It is only valid for the
  /// duration of the access that lent this connection and must not be used to mutate the database.
  public var sqliteConnection: OpaquePointer {
    base.connection
  }

  /// The SQLite build this connection runs against, so raw work uses the same one.
  public var sqlite: SQLiteLibrary {
    base.sqlite
  }

  /// How long this connection waits for a lock another connection or process holds before
  /// reporting `SQLITE_BUSY`.
  ///
  /// It starts at the configuration's ``SQLiteConfiguration/busyTimeout``. A change lasts until the
  /// access that lent this connection ends, when the configured timeout is put back.
  ///
  /// ```swift
  /// try await database.readWithoutTransaction { connection in
  ///   connection.busyTimeout = .limit(.seconds(30))
  ///   return try connection.fetchAll(Reminder.all)
  /// }
  /// ```
  ///
  /// Setting the timeout, and putting the configured one back, both go through
  /// `sqlite3_busy_timeout`, which replaces any busy handler a ``SQLiteConnectionSetup``
  /// installed. An access that leaves this alone keeps such a handler, since the configured
  /// timeout is only put back after a change, but once it is set the connection waits by the
  /// configured timeout rather than the handler.
  public var busyTimeout: SQLiteBusyTimeout {
    get { handle.pointee.settings.busyTimeout }
    nonmutating set { handle.pointee.settings.setBusyTimeout(newValue) }
  }

  /// Creates a cursor over the rows a read query returns.
  ///
  /// The statement runs in its own implicit transaction, which ends when the cursor does.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this connection's access ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseReadAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try base.cursor(for: query.fragment, cached: cached)
  }

  /// Notifies transaction observers that this connection may have read a database region.
  ///
  /// Use this after a read performed through ``sqliteConnection`` or another API that SQLiteOrbit
  /// cannot track.
  ///
  /// - Parameter region: The region the connection may have read.
  public borrowing func notifyReads(in region: OrbitDatabaseRegion) {
    base.notifyReads(in: region)
  }

  /// Runs `body` in a read transaction, so that everything it reads comes from one snapshot.
  ///
  /// ```swift
  /// let (reminders, count) = try connection.transaction { transaction in
  ///   (try transaction.fetchAll(Reminder.all), try transaction.fetchCount(Reminder.all))
  /// }
  /// ```
  ///
  /// - Important: Transactions do not nest. Use a savepoint inside the transaction in hand instead.
  ///
  /// - Parameter body: Receives the transaction. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when the transaction cannot be opened.
  public borrowing func transaction<Result: ~Copyable>(
    _ body: (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try state.inTransaction {
      try handle.pointee.runRead(observations: base.observations, body)
    }
  }
}

/// A connection lent by a native SQLite driver for writing outside a transaction.
///
/// Each statement commits on its own as it finishes, which is what a few statements need: a
/// foreign keys change, for example, is ignored inside a transaction, and `VACUUM` cannot run
/// inside one at all. Call ``transaction(_:)`` to group statements so that they commit or roll
/// back together. Statements that begin or end a transaction or a savepoint are refused outside
/// ``transaction(_:)``, so the connection always knows whether it is inside one.
///
/// Observers see a statement outside a transaction as a commit as soon as it finishes: its changed
/// regions followed by ``OrbitDatabaseTransactionObserver/databaseDidCommit(_:)``, without
/// ``OrbitDatabaseTransactionObserver/databaseWillCommit(_:)``. There are no write cursors, because
/// a statement outside a transaction only commits once it finishes or is reset, so a partly read
/// `RETURNING` cursor would have no clear moment at which its changes committed.
///
/// ```swift
/// try await database.writeWithoutTransaction { connection in
///   try connection.setForeignKeysEnabled(false)
///   try connection.transaction { transaction in
///     try transaction.execute("ALTER TABLE reminders RENAME TO old_reminders")
///     // ...
///   }
/// }
/// ```
///
/// The ``busyTimeout`` and foreign key enforcement this connection changes are put back when the
/// access that lent it ends, even when it throws. Any other pragma it runs stays changed on the
/// connection, so restore it before returning.
public struct SQLiteWriteConnection: OrbitDatabaseReadTransaction, ~Copyable, ~Escapable {
  /// The row this connection's cursors lend.
  public typealias Row = SQLiteRow

  /// The cursor this connection lends.
  public typealias RowCursor = SQLiteRowCursor

  // A statement outside a transaction runs through the same view a write transaction lends, and
  // SQLite commits it on its own as it finishes.
  let base: SQLiteWriteTransaction
  let handle: UnsafePointer<SQLiteHandle>
  let state: SQLiteConnectionState

  @_lifetime(borrow handle)
  init(
    handle: borrowing SQLiteHandle,
    at address: UnsafePointer<SQLiteHandle>,
    observations: OrbitDatabaseTransactionObservationContext,
    state: SQLiteConnectionState
  ) {
    self.base = SQLiteWriteTransaction(handle: handle, observations: observations)
    self.handle = address
    self.state = state
  }

  /// The underlying `sqlite3 *`.
  ///
  /// This is the escape hatch for work the package does not model. It is only valid for the
  /// duration of the access that lent this connection. Report what raw work changes with
  /// ``notifyChanges(in:)``.
  public var sqliteConnection: OpaquePointer {
    base.sqliteConnection
  }

  /// The SQLite build this connection runs against, so raw work uses the same one.
  public var sqlite: SQLiteLibrary {
    base.sqlite
  }

  /// How long this connection waits for a lock another connection or process holds before
  /// reporting `SQLITE_BUSY`.
  ///
  /// It starts at the configuration's ``SQLiteConfiguration/busyTimeout``. A change lasts until the
  /// access that lent this connection ends, when the configured timeout is put back.
  ///
  /// ```swift
  /// try await database.writeWithoutTransaction { connection in
  ///   connection.busyTimeout = .limit(.seconds(30))
  ///   try connection.execute("VACUUM")
  /// }
  /// ```
  ///
  /// Setting the timeout, and putting the configured one back, both go through
  /// `sqlite3_busy_timeout`, which replaces any busy handler a ``SQLiteConnectionSetup``
  /// installed. An access that leaves this alone keeps such a handler, since the configured
  /// timeout is only put back after a change, but once it is set the connection waits by the
  /// configured timeout rather than the handler.
  public var busyTimeout: SQLiteBusyTimeout {
    get { handle.pointee.settings.busyTimeout }
    nonmutating set { handle.pointee.settings.setBusyTimeout(newValue) }
  }

  /// Whether this connection enforces foreign keys.
  ///
  /// It starts at the configuration's ``SQLiteConfiguration/isForeignKeysEnabled`` and changes
  /// only through ``setForeignKeysEnabled(_:)``. A `PRAGMA foreign_keys` statement run directly is
  /// not reflected here, and is not undone when the access ends.
  public var isForeignKeysEnabled: Bool {
    handle.pointee.settings.isForeignKeysEnabled
  }

  /// Turns foreign key enforcement on or off until the access that lent this connection ends, when
  /// the configured setting is put back.
  ///
  /// This is a method rather than a settable ``isForeignKeysEnabled`` because it runs a
  /// `PRAGMA foreign_keys` statement, which can fail, and a setter cannot throw. The statement
  /// runs outside any transaction, which is the only place SQLite honors it.
  ///
  /// ```swift
  /// try await database.writeWithoutTransaction { connection in
  ///   try connection.setForeignKeysEnabled(false)
  ///   try connection.transaction { transaction in
  ///     try transaction.execute("DROP TABLE reminders")
  ///   }
  /// }
  /// ```
  ///
  /// - Important: Calling this inside this connection's own ``transaction(_:)`` is a programming
  ///   error and stops the process, since SQLite would silently ignore it there.
  ///
  /// - Parameter isEnabled: Whether foreign keys are enforced.
  /// - Throws: A ``SQLiteError`` when the pragma fails, in which case the setting is unchanged.
  public borrowing func setForeignKeysEnabled(_ isEnabled: Bool) throws {
    precondition(
      !state.isInTransaction,
      """
      Foreign keys cannot be turned on or off inside a connection's transaction: SQLite ignores \
      PRAGMA foreign_keys while a transaction is open. Call setForeignKeysEnabled before the \
      transaction begins.
      """
    )
    try handle.pointee.settings.setForeignKeysEnabled(isEnabled)
  }

  /// Creates a cursor over the rows a read query returns.
  ///
  /// The statement runs in its own implicit transaction, which ends when the cursor does.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this connection's access ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseReadAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try base.rowCursor(query, cached: cached)
  }

  /// Runs a statement to completion, committing it, and reports how many rows it changed.
  ///
  /// ```swift
  /// let deleted = try connection.execute(Reminder.where(\.isCompleted).delete())
  /// ```
  ///
  /// - Parameter statement: The statement to run. Any rows it returns are stepped past and
  ///   discarded.
  /// - Returns: The number of rows the statement inserted, updated, or deleted.
  /// - Throws: A ``SQLiteError`` when the statement fails, in which case SQLite undoes whatever it
  ///   had changed.
  @discardableResult
  public borrowing func execute(_ statement: some Statement) throws -> Int {
    defer { commitPendingChanges() }
    return try base.execute(OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(statement))
  }

  /// Runs SQL that the query builder does not model, such as schema changes and pragmas.
  ///
  /// Several statements may be given at once, separated by semicolons. Each commits on its own as
  /// it finishes, so a failing statement leaves the ones before it committed. Any rows they produce
  /// are discarded.
  ///
  /// ```swift
  /// try connection.execute("VACUUM")
  /// ```
  ///
  /// - Parameter sql: One or more statements.
  /// - Throws: A ``SQLiteError`` naming the SQL that failed.
  public borrowing func execute(_ sql: String) throws {
    defer { commitPendingChanges() }
    try base.execute(sql)
  }

  /// Notifies transaction observers that this connection changed a database region.
  ///
  /// Use this after a write performed through ``sqliteConnection`` or another API that SQLiteOrbit
  /// cannot track. Outside a transaction such a write has already committed, so observers are told
  /// that it did.
  ///
  /// - Parameter region: The region the connection may have changed.
  public borrowing func notifyChanges(in region: OrbitDatabaseRegion) {
    base.notifyChanges(in: region)
    commitPendingChanges()
  }

  /// Notifies transaction observers that this connection may have read a database region.
  ///
  /// Use this after a read performed through ``sqliteConnection`` or another API that SQLiteOrbit
  /// cannot track.
  ///
  /// - Parameter region: The region the connection may have read.
  public borrowing func notifyReads(in region: OrbitDatabaseRegion) {
    base.notifyReads(in: region)
  }

  /// Runs `body` in a write transaction, committing it when `body` returns and rolling it back
  /// when `body` throws.
  ///
  /// Observers see the same lifecycle as they do for ``OrbitDatabaseWriter/write(_:)``. Savepoints
  /// may be used inside the transaction.
  ///
  /// ```swift
  /// try connection.transaction { transaction in
  ///   try transaction.execute(Reminder.insert { Reminder.Draft(title: "Get milk") })
  ///   try transaction.execute(Reminder.insert { Reminder.Draft(title: "Walk the dog") })
  /// }
  /// ```
  ///
  /// - Important: Transactions do not nest. Use a savepoint inside the transaction in hand instead.
  ///
  /// - Parameter body: Receives the transaction. It cannot escape the call.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError`` when the transaction cannot be opened
  ///   or committed.
  public borrowing func transaction<Result: ~Copyable>(
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try state.inTransaction {
      try handle.pointee.runWrite(observations: base.base.observations, body)
    }
  }

  private borrowing func commitPendingChanges() {
    // Only a statement outside a transaction has committed by the time it finishes. One run while
    // a transaction is open is left for that transaction's own commit or rollback to settle.
    guard !state.isInTransaction else { return }
    base.base.observations.didCommitPendingChanges()
  }
}

/// Tracks whether a connection lent outside a transaction is inside its own `transaction` call.
///
/// The handle's authorizer consults this to refuse statements that begin or end a transaction
/// anywhere else.
final class SQLiteConnectionState {
  private(set) var isInTransaction = false

  func inTransaction<Result: ~Copyable>(_ body: () throws -> Result) rethrows -> Result {
    precondition(
      !isInTransaction,
      """
      A connection's transaction cannot be nested inside another one: the inner BEGIN would fail \
      and its rollback would end the outer transaction. Use a savepoint inside the transaction \
      already in hand.
      """
    )
    isInTransaction = true
    defer { isInTransaction = false }
    return try body()
  }
}
