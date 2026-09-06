final class SQLiteStatementCache {
  private let library: UnsafePointer<SQLiteLibrary>
  private let connection: OpaquePointer
  private let authorizer: SQLiteAuthorizerDispatcher
  private let capacity: Int

  private var idle: [String: SQLitePreparedStatement] = [:]

  init(
    library: UnsafePointer<SQLiteLibrary>,
    connection: OpaquePointer,
    authorizer: SQLiteAuthorizerDispatcher,
    capacity: Int
  ) {
    self.library = library
    self.connection = connection
    self.authorizer = authorizer
    self.capacity = max(0, capacity)
  }

  func prepare(_ sql: String) throws -> SQLitePreparedStatement {
    try prepare(sql, flags: 0)
  }

  func checkOut(_ sql: String) throws -> SQLitePreparedStatement {
    if let statement = idle.removeValue(forKey: sql) {
      return statement
    }
    // A cache that keeps nothing gains nothing from hinting that the statement will be reused.
    return try prepare(sql, flags: capacity > 0 ? SQLitePrepareFlags.persistent.rawValue : 0)
  }

  private func prepare(_ sql: String, flags: UInt32) throws -> SQLitePreparedStatement {
    var statement: OpaquePointer?
    let (code, authorizations) = authorizer.recordingAuthorizations {
      sql.withCString {
        library.pointee.prepare_v3(connection, $0, -1, flags, &statement, nil)
      }
    }
    guard code == SQLiteResultCode.ok.rawValue, let statement else {
      if let statement {
        _ = library.pointee.finalize(statement)
      }
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
    }
    return SQLitePreparedStatement(
      pointer: statement,
      authorizations: authorizations,
      connection: connection,
      authorizer: authorizer,
      library: library
    )
  }

  func checkIn(_ statement: SQLitePreparedStatement, sql: String) {
    _ = library.pointee.reset(statement.pointer)
    _ = library.pointee.clear_bindings(statement.pointer)
    guard idle.count < capacity, idle[sql] == nil else {
      _ = library.pointee.finalize(statement.pointer)
      return
    }
    idle[sql] = statement
  }

  func finalizeAll() {
    for statement in idle.values {
      _ = library.pointee.finalize(statement.pointer)
    }
    idle.removeAll()
  }
}

struct SQLitePreparedStatement {
  let pointer: OpaquePointer
  let readRegion: OrbitDatabaseRegion
  let changedRegion: OrbitDatabaseRegion

  init(
    pointer: OpaquePointer,
    authorizations: [SQLiteAuthorization],
    connection: OpaquePointer,
    authorizer: SQLiteAuthorizerDispatcher?,
    library: UnsafePointer<SQLiteLibrary>
  ) {
    self.pointer = pointer
    self.readRegion = sqliteDatabaseRegion(readBy: authorizations) { table in
      guard let authorizer else { return nil }
      return sqliteResolvedSchema(
        for: table,
        on: connection,
        library: library,
        authorizer: authorizer
      )
    }
    var changedRegion = OrbitDatabaseRegion.empty
    for authorization in authorizations {
      changedRegion.formUnion(authorization.changedRegion)
    }
    if changedRegion.isEmpty && library.pointee.stmt_readonly(pointer) == 0 {
      changedRegion = .fullDatabase
    }
    self.changedRegion = changedRegion
  }
}

extension SQLiteAuthorization {
  var changedRegion: OrbitDatabaseRegion {
    let schema = schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
    switch actionCode {
    case 9, 18:  // SQLITE_DELETE, SQLITE_INSERT
      guard let table = firstArgument else { return .fullDatabase }
      return OrbitDatabaseRegion(table: table, schema: schema)
    case 23:  // SQLITE_UPDATE
      guard let table = firstArgument, let column = secondArgument else { return .fullDatabase }
      return OrbitDatabaseRegion(column: column, in: table, schema: schema)
    case 1...8, 10...17, 24...30:  // Schema changes, ATTACH, DETACH, REINDEX, ANALYZE.
      return .fullDatabase
    default:
      return .empty
    }
  }
}
