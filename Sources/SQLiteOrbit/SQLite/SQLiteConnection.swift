#if StructuredQueries
  public import StructuredQueriesSQLite
#endif

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
///   let mode = try connection.fetchOne("PRAGMA journal_mode") { $0[0].textValue }
///   let count = try connection.transaction { transaction in
///     try transaction.fetchOne("SELECT count(*) FROM reminders") { $0[0].integerValue }
///   }
///   return (mode, count)
/// }
/// ```
public struct SQLiteReadConnection: SQLiteTransaction, ~Copyable, ~Escapable {
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

  /// The configuration this connection was opened with.
  ///
  /// This is the configuration the driver was given. What a driver adds for a connection's role,
  /// such as the `PRAGMA query_only` a pool's readers run, is not part of it, and neither is a
  /// change to ``busyTimeout``.
  public var configuration: SQLiteConfiguration {
    base.configuration
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
  ///   return try connection.fetchAll("SELECT title FROM reminders") { $0[0].textValue }
  /// }
  /// ```
  ///
  /// Setting the timeout goes through `sqlite3_busy_timeout`, which SQLite implements as a busy
  /// handler and which therefore replaces whatever handler the connection had. A
  /// ``SQLiteConfiguration/busyHandler`` is reinstalled along with the configured timeout when the
  /// access ends, so the replacement lasts no longer than the access that made it. A handler a
  /// ``SQLiteConnectionSetup`` installed itself is not known here and is not put back.
  public var busyTimeout: SQLiteBusyTimeout {
    get { handle.pointee.settings.pointee.busyTimeout }
    nonmutating set { handle.pointee.settings.pointee.setBusyTimeout(newValue) }
  }

  /// Creates a cursor over the rows a read query returns.
  ///
  /// The statement runs in its own implicit transaction, which ends when the cursor does.
  ///
  /// - Parameters:
  ///   - query: The query to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this connection's access ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or one with the
  ///   code ``SQLiteResultCode/readOnly`` when SQLite reports that it may write.
  @_lifetime(borrow self)
  public borrowing func rowCursor(
    _ query: OrbitDatabaseQuery<OrbitDatabaseReadAccess>,
    cached: Bool
  ) throws -> SQLiteRowCursor {
    try base.cursor(for: query.sql, cached: cached, requiresReadOnly: true)
  }

  /// Creates a cursor over the rows raw SQL returns.
  ///
  /// The SQL must only read, and is refused with ``SQLiteResultCode/readOnly`` when it may write.
  ///
  /// ```swift
  /// var cursor = try connection.rowCursor("SELECT title FROM reminders")
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this connection's access ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write.
  @_lifetime(borrow self)
  public borrowing func rowCursor(_ sql: SQL, cached: Bool = false) throws -> SQLiteRowCursor {
    // Spelled out on the concrete type, rather than left to the protocol extension, because
    // Swift 6.3 tears down a failed cursor as garbage when a caller binds one a generic function
    // returned.
    try rowCursor(OrbitDatabaseQuery<OrbitDatabaseReadAccess>(sql), cached: cached)
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
  /// let (titles, count) = try connection.transaction { transaction in
  ///   (
  ///     try transaction.fetchAll("SELECT title FROM reminders") { $0[0].textValue },
  ///     try transaction.fetchOne("SELECT count(*) FROM reminders") { $0[0].integerValue }
  ///   )
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
///   connection.isForeignKeysEnabled = false
///   try connection.transaction { transaction in
///     try transaction.executeScript("ALTER TABLE reminders RENAME TO old_reminders")
///     // ...
///   }
/// }
/// ```
///
/// The ``busyTimeout`` and ``isForeignKeysEnabled`` this connection changes are put back when the
/// access that lent it ends, even when it throws. Any other pragma it runs stays changed on the
/// connection, so restore it before returning.
public struct SQLiteWriteConnection: SQLiteTransaction, ~Copyable, ~Escapable {
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

  /// The configuration this connection was opened with.
  ///
  /// This is the configuration the driver was given. What a driver adds for a connection's role,
  /// such as the `PRAGMA query_only` a pool's readers run, is not part of it, and neither is a
  /// change to ``busyTimeout`` or ``isForeignKeysEnabled``.
  public var configuration: SQLiteConfiguration {
    base.configuration
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
  ///   try connection.executeScript("VACUUM")
  /// }
  /// ```
  ///
  /// Setting the timeout goes through `sqlite3_busy_timeout`, which SQLite implements as a busy
  /// handler and which therefore replaces whatever handler the connection had. A
  /// ``SQLiteConfiguration/busyHandler`` is reinstalled along with the configured timeout when the
  /// access ends, so the replacement lasts no longer than the access that made it. A handler a
  /// ``SQLiteConnectionSetup`` installed itself is not known here and is not put back.
  public var busyTimeout: SQLiteBusyTimeout {
    get { handle.pointee.settings.pointee.busyTimeout }
    nonmutating set { handle.pointee.settings.pointee.setBusyTimeout(newValue) }
  }

  /// Whether this connection enforces foreign keys.
  ///
  /// It starts at the configuration's ``SQLiteConfiguration/isForeignKeysEnabled``. A change lasts
  /// until the access that lent this connection ends, when the configured setting is put back,
  /// even when the access throws.
  ///
  /// ```swift
  /// try await database.writeWithoutTransaction { connection in
  ///   connection.isForeignKeysEnabled = false
  ///   try connection.transaction { transaction in
  ///     try transaction.executeScript("DROP TABLE reminders")
  ///   }
  /// }
  /// ```
  ///
  /// SQLite changes foreign keys with a `PRAGMA foreign_keys` statement, which can fail, and a
  /// setter cannot throw. So setting this only records the change. It takes effect just before
  /// this connection's next statement or ``transaction(_:)``, outside any transaction, where
  /// SQLite honors it, and a failure to apply it is thrown from that statement or transaction. The
  /// change then stays pending for the next one to try again. Reading this returns the value last
  /// set, whether or not it has taken effect.
  ///
  /// Work done through ``sqliteConnection`` does not apply a pending change first. A
  /// `PRAGMA foreign_keys` statement run directly is not reflected here, and is not undone when the
  /// access ends.
  ///
  /// - Important: Setting this inside this connection's own ``transaction(_:)`` is a programming
  ///   error and stops the process, since SQLite would silently ignore it there.
  public var isForeignKeysEnabled: Bool {
    get { handle.pointee.settings.pointee.isForeignKeysEnabled }
    nonmutating set {
      precondition(
        !state.isInTransaction,
        """
        Foreign keys cannot be turned on or off inside a connection's transaction: SQLite ignores \
        PRAGMA foreign_keys while a transaction is open. Set isForeignKeysEnabled before the \
        transaction begins.
        """
      )
      handle.pointee.settings.pointee.isForeignKeysEnabled = newValue
    }
  }

  /// How many rows the most recent statement on this connection inserted, updated, or deleted.
  ///
  /// This is `sqlite3_changes64`, which counts the last statement rather than everything the
  /// access has run, so reading it after a second ``execute(_:)`` reports only what that second
  /// statement changed. A statement that changes nothing, such as a `SELECT` or a
  /// `CREATE TABLE`, leaves the previous count in place rather than resetting it to zero.
  ///
  /// ```swift
  /// let deleted = try await database.writeWithoutTransaction { connection in
  ///   try connection.execute("DELETE FROM reminders WHERE is_completed")
  ///   return connection.changesCount
  /// }
  /// ```
  ///
  /// - Important: The count belongs to the connection, not to this access, and the next access may
  ///   be lent a different connection. Read it inside the same access as the write it describes.
  public var changesCount: Int {
    base.changesCount
  }

  /// The rowid of the most recent successful insert on this connection.
  ///
  /// This is `sqlite3_last_insert_rowid`, which is how a table with an `INTEGER PRIMARY KEY`
  /// SQLite filled in reports what it chose. A statement that inserts nothing leaves the previous
  /// rowid in place, and a connection that has never inserted reports `0`.
  ///
  /// ```swift
  /// let id = try await database.writeWithoutTransaction { connection in
  ///   try connection.execute("INSERT INTO reminders (title) VALUES (\("Get milk"))")
  ///   return connection.lastInsertedRowID
  /// }
  /// ```
  ///
  /// - Important: The rowid belongs to the connection, not to this access, and the next access may
  ///   be lent a different connection. Read it inside the same access as the insert it describes.
  public var lastInsertedRowID: Int64 {
    base.lastInsertedRowID
  }

  /// Moves the write-ahead log back into the database file.
  ///
  /// SQLite checkpoints passively on its own as the log grows, which a steady stream of readers
  /// can keep from ever finishing. This is how to make it finish, and with
  /// ``SQLiteWALCheckpointMode/truncate``, how to give the log's disk space back.
  ///
  /// ```swift
  /// let result = try await database.writeWithoutTransaction { connection in
  ///   try connection.checkpoint(.truncate)
  /// }
  /// ```
  ///
  /// A database that is not in WAL mode has no log to move, so the checkpoint succeeds having done
  /// nothing and reports `-1` for both counts. Every mode but ``SQLiteWALCheckpointMode/passive``
  /// waits for other connections by this connection's busy handler or ``busyTimeout``, and one
  /// that gives up before it could finish throws `SQLITE_BUSY` rather than report the part it
  /// did.
  ///
  /// - Parameters:
  ///   - mode: How hard to try. Defaults to ``SQLiteWALCheckpointMode/passive``, which never waits.
  ///   - schema: The attached database to checkpoint. With `nil`, every attached database in WAL
  ///     mode is checkpointed, and SQLite does not say which of them the counts describe, so name
  ///     one when the counts matter.
  /// - Returns: How many frames the log holds and how many of them are in the database file.
  /// - Throws: A ``SQLiteError`` when the checkpoint fails or could not finish.
  public borrowing func checkpoint(
    _ mode: SQLiteWALCheckpointMode = .passive,
    schema: SQLiteSchemaName? = nil
  ) throws -> SQLiteWALCheckpointResult {
    let library = base.base.library
    let connection = base.base.connection
    var logFrameCount: Int32 = -1
    var checkpointedFrameCount: Int32 = -1
    func runCheckpoint(_ name: UnsafePointer<CChar>?) -> Int32 {
      library.pointee.connections.walCheckpoint(
        connection,
        name,
        mode.rawValue,
        &logFrameCount,
        &checkpointedFrameCount
      )
    }
    let code = schema.map { $0.rawValue.withCString(runCheckpoint) } ?? runCheckpoint(nil)
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: nil)
    }
    return SQLiteWALCheckpointResult(
      logFrameCount: Int(logFrameCount),
      checkpointedFrameCount: Int(checkpointedFrameCount)
    )
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
    try applyPendingSettings()
    return try base.rowCursor(query, cached: cached)
  }

  /// Creates a cursor over the rows raw SQL returns.
  ///
  /// A write connection may write, so the SQL is not held to reading.
  ///
  /// ```swift
  /// var cursor = try connection.rowCursor("SELECT title FROM reminders")
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to run.
  ///   - cached: Whether the connection may reuse a prepared statement for this SQL.
  /// - Returns: A cursor valid until this connection's access ends.
  /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
  @_lifetime(borrow self)
  public borrowing func rowCursor(_ sql: SQL, cached: Bool = false) throws -> SQLiteRowCursor {
    // Spelled out on the concrete type, rather than left to the protocol extension, because
    // Swift 6.3 tears down a failed cursor as garbage when a caller binds one a generic function
    // returned.
    try rowCursor(OrbitDatabaseQuery<OrbitDatabaseReadAccess>(sql), cached: cached)
  }

  /// Runs a statement to completion, committing it and discarding any rows it returns.
  ///
  /// ```swift
  /// try connection.execute("DELETE FROM reminders WHERE is_completed")
  /// let deleted = connection.changesCount
  /// ```
  ///
  /// - Parameter sql: The statement to run. Any rows it returns are stepped past and discarded.
  /// - Throws: A ``SQLiteError`` when the statement fails, in which case SQLite undoes whatever it
  ///   had changed.
  public borrowing func execute(_ sql: SQL) throws {
    try applyPendingSettings()
    defer { commitPendingChanges() }
    try base.execute(OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(sql))
  }

  /// Runs a script of one or more statements, such as a schema change or a pragma.
  ///
  /// Statements are separated by semicolons. Each commits on its own as it finishes, so a failing
  /// statement leaves the ones before it committed. Any rows they produce are discarded. A script
  /// takes no parameters: its text is run as it is, so build it only from text the program itself
  /// controls.
  ///
  /// ```swift
  /// try connection.executeScript("VACUUM")
  /// ```
  ///
  /// - Parameter script: One or more statements.
  /// - Throws: A ``SQLiteError`` naming the SQL that failed.
  public borrowing func executeScript(_ script: String) throws {
    try applyPendingSettings()
    defer { commitPendingChanges() }
    try base.executeScript(script)
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
  ///   try transaction.execute("INSERT INTO reminders (title) VALUES (\("Get milk"))")
  ///   try transaction.execute("INSERT INTO reminders (title) VALUES (\("Walk the dog"))")
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
    // Before `BEGIN`, since SQLite ignores a foreign keys change once the transaction is open.
    try applyPendingSettings()
    return try state.inTransaction {
      try handle.pointee.runWrite(observations: base.base.observations, body)
    }
  }

  // Every statement and transaction this connection runs comes through here first, which is what
  // puts a change the `isForeignKeysEnabled` setter could only record into effect.
  private borrowing func applyPendingSettings() throws {
    try handle.pointee.settings.pointee.applyForeignKeys()
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

#if StructuredQueries
  extension SQLiteWriteConnection {
    /// Runs a statement to completion, committing it and discarding any rows it returns.
    ///
    /// ```swift
    /// try connection.execute(Reminder.where(\.isCompleted).delete())
    /// let deleted = connection.changesCount
    /// ```
    ///
    /// - Parameter statement: The statement to run. Any rows it returns are stepped past and
    ///   discarded.
    /// - Throws: A ``SQLiteError`` when the statement fails, in which case SQLite undoes whatever
    ///   it had changed.
    public borrowing func execute(_ statement: some Statement) throws {
      try execute(SQL(fragment: statement.query))
    }
  }
#endif
