/// A scope-checked view of a borrowed SQLite connection.
///
/// Use `withScopedAccess` when integrating an API that stores connection or cursor objects and
/// cannot accept nonescapable native handles. The view does not own or close the connection.
/// It is valid only on the creating thread and inside its access closure. Operations throw
/// `SQLiteResultCode.misuse` after that closure returns or when called from another thread.
/// Outstanding statements are finalized before the closure returns, even if their cursors escape.
///
/// Native borrowed transactions remain useful when the compiler can enforce their lifetime.
///
/// ```swift
/// try database.readBlocking { transaction in
///   try transaction.withScopedAccess { access in
///     let cursor = try access.statementCursor("SELECT title FROM reminders")
///     while let row = try cursor.next() { print(row[0].value.textValue ?? "") }
///   }
/// }
/// ```
public final class SQLiteScopedAccess {
  let connection: OpaquePointer
  let library: UnsafePointer<SQLiteLibrary>
  let statements: SQLiteStatementCache
  let authorizer: SQLiteAuthorizerDispatcher
  let observations: SQLiteConnectionEvents
  let readOnly: Bool
  let configurationPointer: UnsafePointer<SQLiteConfiguration>
  let connectionState: SQLiteConnectionState?
  private let thread = ThreadID.current
  private var active = true
  private var cursors: [SQLiteStatementCursor] = []
  var runTransaction:
    ((SQLiteWriteTransactionMode, (SQLiteScopedAccess) throws -> Void) throws -> Void)?
  private let transactionWasOpen: Bool

  init(_ transaction: borrowing SQLiteReadTransaction, readOnly: Bool) {
    connection = transaction.connection
    library = transaction.library
    statements = transaction.statements
    authorizer = transaction.authorizer
    observations = transaction.observations
    connectionState = transaction.connectionState
    self.readOnly = readOnly
    configurationPointer = transaction.access.configurationPointer
    transactionWasOpen = transaction.sqlite.connections.isAutocommit(transaction.connection) == 0
  }

  init(setup access: borrowing SQLiteConnectionAccess) {
    connection = access.sqliteConnection
    library = access.libraryPointer
    authorizer = access.authorizer
    statements = access.statements
    observations = access.scopedAccess?.observations ?? SQLiteConnectionEvents()
    connectionState = access.scopedAccess?.connectionState
    readOnly = access.scopedAccess?.readOnly ?? false
    runTransaction = access.scopedAccess?.runTransaction
    configurationPointer = access.configurationPointer
    transactionWasOpen = access.sqlite.connections.isAutocommit(access.sqliteConnection) == 0
  }

  /// Checks that the view is still inside its closure and on the creating thread.
  public func checkAccess() throws {
    guard thread == .current else {
      throw SQLiteError(code: .misuse, message: "database access from another thread")
    }
    guard active else {
      throw SQLiteError(code: .misuse, message: "database access outlived its closure")
    }
  }

  func invalidate() {
    for cursor in cursors { cursor.finish() }
    cursors.removeAll()
    active = false
  }

  /// The underlying connection, valid only inside this scope. Raw mutations require write access
  /// and must participate in the native driver's observation protocol.
  public var sqliteConnection: OpaquePointer {
    get throws {
      try checkAccess()
      return connection
    }
  }
  /// The immutable configuration supplied when opening this connection.
  public var configuration: SQLiteConfiguration {
    get throws {
      try checkAccess()
      return configurationPointer.pointee
    }
  }
  /// The number of rows changed by the most recent statement on this connection.
  public var changesCount: Int {
    get throws {
      try checkAccess()
      return Int(library.pointee.connections.changes(connection))
    }
  }
  /// The rowid of the most recent successful insert on this connection.
  public var lastInsertedRowID: Int64 {
    get throws {
      try checkAccess()
      return library.pointee.connections.lastInsertedRowID(connection)
    }
  }
  /// Whether SQLite currently has a transaction open on this connection.
  public var isInsideTransaction: Bool {
    get throws {
      try checkAccess()
      return library.pointee.connections.isAutocommit(connection) == 0
    }
  }

  /// Prepares and binds one statement and returns a lazy cursor of owned rows.
  ///
  /// Read scopes refuse statements that may write. Write scopes accept reads and writes, including
  /// `RETURNING`. A cached cursor borrows its statement until exhausted, closed, or the scope ends.
  /// Transaction control outside a managed transaction is refused.
  public func statementCursor(_ sql: SQL, cached: Bool = false) throws -> SQLiteStatementCursor {
    try checkAccess()
    if try transactionWasOpen && !isInsideTransaction {
      throw SQLiteError(
        code: SQLiteResultCode(rawValue: 4),
        message: "transaction was aborted",
        sql: sql.text
      )
    }
    let cursor = try SQLiteStatementCursor(access: self, sql: sql, cached: cached)
    // Drop completed cursors without retaining one object per query for the whole transaction.
    cursors.removeAll { $0.prepared == nil }
    cursors.append(cursor)
    return cursor
  }

  /// Splits off the first executable statement, returning its text and the remaining script.
  /// SQLite determines boundaries, including semicolons inside trigger bodies. The statement is
  /// compiled but never executed. Empty SQL and comments return a nil statement.
  public func firstStatement(_ sql: String) throws -> (statement: String?, remainder: String) {
    try checkAccess()
    return try sql.withCString { start in
      var current = start
      while current.pointee != 0 {
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let code = library.pointee.statements.preparation.prepare(
          connection,
          current,
          -1,
          0,
          &statement,
          &tail
        )
        defer {
          if let statement { _ = library.pointee.statements.execution.finalize(statement) }
        }
        guard code == SQLiteResultCode.ok.rawValue else {
          throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
        }
        guard let tail, tail > current else { break }
        if statement != nil {
          return (
            String(
              decoding: UnsafeRawBufferPointer(
                start: current,
                count: current.distance(to: tail)
              ),
              as: UTF8.self
            ), String(cString: tail)
          )
        }
        current = tail
      }
      return (nil, "")
    }
  }

  /// Runs a managed write transaction, committing when the body returns and rolling back on error.
  ///
  /// Available only when `withScopedAccess` was called on a `SQLiteWriteConnection` outside a
  /// transaction. Transactions do not nest. The inner view is invalidated when its body returns.
  public func transaction<Result>(
    mode: SQLiteWriteTransactionMode = .immediate,
    _ body: (SQLiteScopedAccess) throws -> Result
  ) throws -> Result {
    try checkAccess()
    guard let runTransaction else {
      throw SQLiteError(code: .misuse, message: "transactions require access to a write connection")
    }
    var result: Result?
    try runTransaction(mode) { result = .some(try body($0)) }
    return result!
  }

  /// Compiles read-only SQL and returns the region it reads without executing it.
  public func region(for sql: SQL) throws -> OrbitDatabaseRegion {
    try checkAccess()
    guard let prepared = try statements.prepare(sql.text, requiresReadOnly: true) else {
      return .empty
    }
    defer { _ = library.pointee.statements.execution.finalize(prepared.pointer) }
    return prepared.readRegion
  }

  /// Reports reads performed through the raw connection so value observations can track them.
  public func notifyReads(in region: OrbitDatabaseRegion) throws {
    try checkAccess()
    observations.didRead(in: region)
  }

  /// Reports successful raw mutations. Changes inside a transaction remain provisional until it
  /// commits; changes outside one are reported as committed immediately. Requires write access.
  public func notifyChanges(in region: OrbitDatabaseRegion) throws {
    try checkAccess()
    guard !readOnly else {
      throw SQLiteError(code: .readOnly, message: "changes require write access")
    }
    observations.didChange(in: region)
    if !(try isInsideTransaction) { observations.didCommitPendingChanges() }
  }

  /// Compiles one statement and returns its result columns, regions, and parameter count.
  /// Read scopes refuse statements that may write. The statement is never executed.
  public func statementInfo(_ sql: String) throws -> SQLiteStatementInfo {
    try checkAccess()
    guard let prepared = try statements.prepare(sql, requiresReadOnly: readOnly) else {
      return SQLiteStatementInfo(
        columnNames: [],
        readRegion: .empty,
        changedRegion: .empty,
        isReadOnly: true,
        parameterCount: 0
      )
    }
    defer { _ = library.pointee.statements.execution.finalize(prepared.pointer) }
    let names = (0..<library.pointee.columns.count(prepared.pointer))
      .map {
        library.pointee.columns.name(prepared.pointer, $0).map(String.init(cString:)) ?? ""
      }
    return SQLiteStatementInfo(
      columnNames: names,
      readRegion: prepared.readRegion,
      changedRegion: prepared.changedRegion,
      isReadOnly: prepared.isReadOnly,
      parameterCount: Int(library.pointee.bindings.parameterCount(prepared.pointer))
    )
  }

  /// Lends the native connection access for function installation, collation installation, or
  /// authorization changes. The native view cannot escape the synchronous body. Raw SQL through
  /// it must respect this scope's read/write permissions and use `notifyReads` or `notifyChanges`.
  public func withConnectionAccess<Result>(
    _ body: (borrowing SQLiteConnectionAccess) throws -> Result
  ) throws -> Result {
    try checkAccess()
    return try body(SQLiteConnectionAccess(scopedAccess: self))
  }
}

/// A lazy cursor of owned row values, confined to the `SQLiteScopedAccess` that created it.
///
/// Its rows may be retained across advances. The cursor itself must be advanced or closed on the
/// creating thread, before that scope returns. All remaining statements are closed at scope end.
public final class SQLiteStatementCursor: OrbitDatabaseCursor {
  /// A row in column order; duplicate column names are preserved.
  public typealias Element = [(name: String, value: OrbitDatabaseValue)]
  private let access: SQLiteScopedAccess
  private let sql: String
  private let cached: Bool
  private let authorizationGeneration: UInt64
  var prepared: SQLitePreparedStatement?
  private var published = false
  private var exhausted = false
  /// The result column names reported when the statement was prepared.
  public private(set) var columnNames: [String] = []
  /// The region read by the statement; refreshed when SQLite recompiles it.
  public private(set) var readRegion = OrbitDatabaseRegion.empty

  init(access: SQLiteScopedAccess, sql: SQL, cached: Bool) throws {
    self.access = access
    self.sql = sql.text
    self.cached = cached
    authorizationGeneration = access.authorizer.generation
    prepared =
      cached
      ? try access.statements.checkOut(sql.text, requiresReadOnly: access.readOnly)
      : try access.statements.prepare(sql.text, requiresReadOnly: access.readOnly)
    if let prepared {
      readRegion = prepared.readRegion
      columnNames = (0..<access.library.pointee.columns.count(prepared.pointer))
        .map {
          access.library.pointee.columns.name(prepared.pointer, $0).map(String.init(cString:)) ?? ""
        }
      access.authorizer.activeCursors += 1
      do {
        guard access.library.pointee.bindings.parameterCount(prepared.pointer) == sql.bindings.count
        else {
          throw SQLiteError(
            code: .misuse,
            message: "wrong number of statement arguments",
            sql: sql.text
          )
        }
        try bind(sql, to: prepared.pointer, library: access.library)
      } catch {
        finish()
        throw error
      }
    }
  }

  // The access retains a cursor until it is closed, so destruction never touches an expired handle.
  func finish() {
    guard let prepared else { return }
    access.authorizer.activeCursors -= 1
    if cached {
      access.statements.checkIn(prepared, sql: sql)
    } else {
      _ = access.library.pointee.statements.execution.finalize(prepared.pointer)
    }
    self.prepared = nil
    exhausted = true
  }

  /// Returns or finalizes the prepared statement early. Repeated closes inside the scope do nothing.
  public func close() throws {
    try access.checkAccess()
    finish()
  }

  /// Returns an owned row, or nil once exhausted. A failed statement is reported once.
  public func next() throws -> Element? {
    try access.checkAccess()
    guard !exhausted, let statement = prepared?.pointer else { return nil }
    guard authorizationGeneration == access.authorizer.generation else {
      finish()
      throw SQLiteError(
        code: .misuse,
        message: "A cursor cannot cross an authorization scope boundary",
        sql: sql
      )
    }
    if prepared?.controlsTransactions == true, access.connectionState?.isInTransaction == false {
      finish()
      throw SQLiteError(
        code: .auth,
        message: "Transaction control requires connection.transaction",
        sql: sql
      )
    }
    let code: Int32
    if !published {
      published = true
      let (firstCode, authorizations) = access.authorizer.recordingAuthorizations {
        access.library.pointee.statements.execution.step(statement)
      }
      code = firstCode
      if !authorizations.isEmpty {
        access.statements.invalidate()
        prepared =
          access.statements.refreshedMetadata(for: statement, sql: sql)
          ?? SQLitePreparedStatement(
            pointer: statement,
            isReadOnly: access.library.pointee.statements.inspection.isReadOnly(statement) != 0,
            authorizations: authorizations,
            cacheGeneration: access.statements.generation,
            statements: access.statements,
            connection: access.connection,
            authorizer: access.authorizer,
            library: access.library
          )
      }
      if let prepared {
        readRegion = prepared.readRegion
        access.observations.didRead(in: prepared.readRegion)
        access.observations.didChange(in: prepared.changedRegion)
        if prepared.invalidatesStatementCache { access.statements.invalidate() }
      }
    } else {
      code = access.library.pointee.statements.execution.step(statement)
    }
    switch code {
    case SQLiteResultCode.row.rawValue:
      return (0..<access.library.pointee.columns.count(statement))
        .map { index in
          (
            access.library.pointee.columns.name(statement, index).map(String.init(cString:)) ?? "",
            access.library.pointee.columns.value(statement, at: index)
          )
        }
    case SQLiteResultCode.done.rawValue:
      finish()
      if !(try access.isInsideTransaction) { access.observations.didCommitPendingChanges() }
      return nil
    default:
      let error = SQLiteError.reported(
        by: access.library.pointee,
        on: access.connection,
        code: code,
        sql: sql
      )
      finish()
      if !(try access.isInsideTransaction) { access.observations.didCommitPendingChanges() }
      throw error
    }
  }
}

extension SQLiteReadTransaction {
  /// Lends a scope-checked connection view to code that requires escapable connection objects.
  /// The view and all its cursors are invalidated before this synchronous closure returns.
  public borrowing func withScopedAccess<Result>(_ body: (SQLiteScopedAccess) throws -> Result)
    rethrows
    -> Result
  {
    let access = SQLiteScopedAccess(self, readOnly: true)
    defer { access.invalidate() }
    return try body(access)
  }
}
extension SQLiteWriteTransaction {
  /// Lends a scope-checked connection view to code that requires escapable connection objects.
  /// The view and all its cursors are invalidated before this synchronous closure returns.
  public borrowing func withScopedAccess<Result>(_ body: (SQLiteScopedAccess) throws -> Result)
    rethrows
    -> Result
  {
    let access = SQLiteScopedAccess(base, readOnly: false)
    defer { access.invalidate() }
    return try body(access)
  }
}
extension SQLiteReadConnection {
  /// Lends a scope-checked connection view to code that requires escapable connection objects.
  /// The view and all its cursors are invalidated before this synchronous closure returns.
  public borrowing func withScopedAccess<Result>(_ body: (SQLiteScopedAccess) throws -> Result)
    rethrows
    -> Result
  {
    try base.withScopedAccess(body)
  }
}
extension SQLiteWriteConnection {
  /// Lends a scope-checked connection view to code that requires escapable connection objects.
  /// The view and all its cursors are invalidated before this synchronous closure returns.
  public borrowing func withScopedAccess<Result>(_ body: (SQLiteScopedAccess) throws -> Result)
    rethrows
    -> Result
  {
    let access = SQLiteScopedAccess(base.base, readOnly: false)
    let handle = handle
    let state = state
    let observations = base.base.observations
    access.runTransaction = { mode, operation in
      try state.inTransaction {
        try handle.pointee.runWrite(mode: mode, observations: observations) { transaction in
          try transaction.withScopedAccess(operation)
        }
      }
    }
    defer { access.invalidate() }
    return try body(access)
  }
}

extension SQLiteConnectionAccess {
  /// Lends a scope-checked connection view to code that requires escapable connection objects.
  /// The view and all its cursors are invalidated before this synchronous closure returns.
  public borrowing func withScopedAccess<Result>(_ body: (SQLiteScopedAccess) throws -> Result)
    rethrows
    -> Result
  {
    let access = SQLiteScopedAccess(setup: self)
    defer { access.invalidate() }
    return try body(access)
  }
}
