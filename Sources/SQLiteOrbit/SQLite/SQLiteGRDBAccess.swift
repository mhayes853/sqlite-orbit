// The compatibility target uses the native cache, authorizer, and observation context. Unlike
// native transactions, GRDB's connection and cursor types are escapable: enforce their lifetime
// and thread confinement at runtime, and finalize all outstanding statements before returning
// the borrowed connection. No compatibility object owns or closes the connection itself.
@_spi(GRDB)
public struct SQLiteGRDBDatabaseInfo: Sendable {
  public let path: OrbitDatabasePath
  public let configuration: SQLiteConfiguration
  public let readerCount: Int
  public init(path: OrbitDatabasePath, configuration: SQLiteConfiguration, readerCount: Int = 1) {
    self.path = path
    self.configuration = configuration
    self.readerCount = readerCount
  }
}

@_spi(GRDB)
public protocol SQLiteGRDBDatabaseMetadata {
  var grdbDatabaseInfo: SQLiteGRDBDatabaseInfo? { get }
}

@_spi(GRDB)
public final class SQLiteGRDBAccess {
  let connection: OpaquePointer
  let library: UnsafePointer<SQLiteLibrary>
  let statements: SQLiteStatementCache
  let authorizer: SQLiteAuthorizerDispatcher
  let observations: SQLiteConnectionEvents
  let readOnly: Bool
  let configuration: UnsafePointer<SQLiteConfiguration>
  let connectionState: SQLiteConnectionState?
  private let thread = ThreadID.current
  private var active = true
  private var cursors: [SQLiteGRDBCursor] = []
  var runTransaction: (((SQLiteGRDBAccess) throws -> Bool) throws -> Void)?
  private let transactionWasOpen: Bool

  init(_ transaction: borrowing SQLiteReadTransaction, readOnly: Bool) {
    connection = transaction.connection
    library = transaction.library
    statements = transaction.statements
    authorizer = transaction.authorizer
    observations = transaction.observations
    connectionState = transaction.connectionState
    self.readOnly = readOnly
    configuration = transaction.access.configurationPointer
    transactionWasOpen = transaction.sqlite.connections.isAutocommit(transaction.connection) == 0
  }

  init(setup access: borrowing SQLiteConnectionAccess) {
    connection = access.sqliteConnection
    library = access.libraryPointer
    authorizer = access.authorizer
    statements = access.statements
    observations = SQLiteConnectionEvents()
    connectionState = nil
    readOnly = false
    configuration = access.configurationPointer
    transactionWasOpen = access.sqlite.connections.isAutocommit(access.sqliteConnection) == 0
  }

  public func checkAccess() throws {
    guard thread == .current else {
      throw SQLiteError(code: .misuse, message: "database access from another thread")
    }
    guard active else {
      throw SQLiteError(code: .misuse, message: "database access outlived its closure")
    }
  }

  func invalidate() {
    for cursor in cursors { cursor.close() }
    cursors.removeAll()
    active = false
  }

  public var sqliteConnection: OpaquePointer { connection }
  public var changesCount: Int64 { library.pointee.connections.changes(connection) }
  public var lastInsertedRowID: Int64 { library.pointee.connections.lastInsertedRowID(connection) }
  public var isInsideTransaction: Bool { library.pointee.connections.isAutocommit(connection) == 0 }

  public func cursor(_ sql: SQL, cached: Bool = false) throws -> SQLiteGRDBCursor {
    try checkAccess()
    if transactionWasOpen && !isInsideTransaction {
      throw SQLiteError(
        code: SQLiteResultCode(rawValue: 4),
        message: "transaction was aborted",
        sql: sql.text
      )
    }
    let cursor = try SQLiteGRDBCursor(access: self, sql: sql, cached: cached)
    // Drop completed cursors without retaining one object per query for the whole transaction.
    cursors.removeAll { $0.prepared == nil }
    cursors.append(cursor)
    return cursor
  }

  /// SQLite, rather than a semicolon scanner, determines statement boundaries (including triggers).
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

  public func inTransaction(_ body: (SQLiteGRDBAccess) throws -> Bool) throws {
    try checkAccess()
    guard let runTransaction else {
      throw SQLiteError(
        code: .misuse,
        message: "transactions require writeWithoutTransaction access"
      )
    }
    try runTransaction(body)
  }

  public func region(for sql: SQL) throws -> OrbitDatabaseRegion {
    try checkAccess()
    guard let prepared = try statements.prepare(sql.text, requiresReadOnly: true) else {
      return .empty
    }
    defer { _ = library.pointee.statements.execution.finalize(prepared.pointer) }
    return prepared.readRegion
  }

  public func inspectStatement(_ sql: String) throws -> (
    columns: [String], region: OrbitDatabaseRegion
  ) {
    try checkAccess()
    guard let prepared = try statements.prepare(sql, requiresReadOnly: readOnly) else {
      return ([], .empty)
    }
    defer { _ = library.pointee.statements.execution.finalize(prepared.pointer) }
    let names = (0..<library.pointee.columns.count(prepared.pointer))
      .map {
        library.pointee.columns.name(prepared.pointer, $0).map(String.init(cString:)) ?? ""
      }
    return (names, prepared.readRegion)
  }

  public func withConnectionAccess<Result>(
    _ body: (borrowing SQLiteConnectionAccess) throws -> Result
  ) throws -> Result {
    try checkAccess()
    return try body(SQLiteConnectionAccess(grdbAccess: self))
  }
}

@_spi(GRDB)
public final class SQLiteGRDBCursor {
  private let access: SQLiteGRDBAccess
  private let sql: String
  private let cached: Bool
  private let authorizationGeneration: UInt64
  var prepared: SQLitePreparedStatement?
  private var published = false
  private var exhausted = false
  public private(set) var columnNames: [String] = []
  public private(set) var databaseRegion = OrbitDatabaseRegion.empty

  init(access: SQLiteGRDBAccess, sql: SQL, cached: Bool) throws {
    self.access = access
    self.sql = sql.text
    self.cached = cached
    authorizationGeneration = access.authorizer.generation
    prepared =
      cached
      ? try access.statements.checkOut(sql.text, requiresReadOnly: access.readOnly)
      : try access.statements.prepare(sql.text, requiresReadOnly: access.readOnly)
    if let prepared {
      databaseRegion = prepared.readRegion
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
        close()
        throw error
      }
    }
  }

  // The access retains a cursor until it is closed, so destruction never touches an expired handle.
  func close() {
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

  public func release() {
    // A misplaced cursor must never finalize a no-mutex connection from another thread. The
    // access still owns it and will close it on the connection's thread when the scope ends.
    guard (try? access.checkAccess()) != nil else { return }
    close()
  }

  public func next() throws -> [(String, OrbitDatabaseValue)]? {
    try access.checkAccess()
    guard !exhausted, let statement = prepared?.pointer else { return nil }
    guard authorizationGeneration == access.authorizer.generation else {
      close()
      throw SQLiteError(
        code: .misuse,
        message: "A cursor cannot cross an authorization scope boundary",
        sql: sql
      )
    }
    if prepared?.controlsTransactions == true, access.connectionState?.isInTransaction == false {
      close()
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
        databaseRegion = prepared.readRegion
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
      close()
      if !access.isInsideTransaction { access.observations.didCommitPendingChanges() }
      return nil
    default:
      let error = SQLiteError.reported(
        by: access.library.pointee,
        on: access.connection,
        code: code,
        sql: sql
      )
      close()
      throw error
    }
  }
}

extension SQLiteReadTransaction {
  @_spi(GRDB)
  public borrowing func withGRDBAccess<Result>(_ body: (SQLiteGRDBAccess) throws -> Result) rethrows
    -> Result
  {
    let access = SQLiteGRDBAccess(self, readOnly: true)
    defer { access.invalidate() }
    return try body(access)
  }
}
extension SQLiteWriteTransaction {
  @_spi(GRDB)
  public borrowing func withGRDBAccess<Result>(_ body: (SQLiteGRDBAccess) throws -> Result) rethrows
    -> Result
  {
    let access = SQLiteGRDBAccess(base, readOnly: false)
    defer { access.invalidate() }
    return try body(access)
  }
}
extension SQLiteReadConnection {
  @_spi(GRDB)
  public borrowing func withGRDBAccess<Result>(_ body: (SQLiteGRDBAccess) throws -> Result) rethrows
    -> Result
  {
    try base.withGRDBAccess(body)
  }
}
extension SQLiteWriteConnection {
  @_spi(GRDB)
  public borrowing func withGRDBAccess<Result>(_ body: (SQLiteGRDBAccess) throws -> Result) rethrows
    -> Result
  {
    let access = SQLiteGRDBAccess(base.base, readOnly: false)
    let handle = handle
    let state = state
    let observations = base.base.observations
    access.runTransaction = { operation in
      do {
        try state.inTransaction {
          try handle.pointee.runWrite(mode: .immediate, observations: observations) { transaction in
            try transaction.withGRDBAccess { nestedAccess in
              if try !operation(nestedAccess) { throw SQLiteGRDBRollback() }
            }
          }
        }
      } catch is SQLiteGRDBRollback {}
    }
    defer { access.invalidate() }
    return try body(access)
  }
}

private struct SQLiteGRDBRollback: Error {}

extension SQLiteConnectionAccess {
  @_spi(GRDB)
  public borrowing func withGRDBAccess<Result>(_ body: (SQLiteGRDBAccess) throws -> Result) rethrows
    -> Result
  {
    let access = SQLiteGRDBAccess(setup: self)
    defer { access.invalidate() }
    return try body(access)
  }
}
