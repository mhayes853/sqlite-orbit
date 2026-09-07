import StructuredQueries

final class SQLiteStatementCache {
  private struct Table: Hashable {
    let schema: SQLiteSchemaName
    let name: String
  }

  private let library: UnsafePointer<SQLiteLibrary>
  private let connection: OpaquePointer
  private let authorizer: SQLiteAuthorizerDispatcher
  private let capacity: Int

  private var idle: [String: SQLitePreparedStatement] = [:]
  private var generatedColumnsByTable: [Table: Set<String>] = [:]
  private var generation: UInt64 = 0

  var currentGeneration: UInt64 { generation }

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
      cacheGeneration: generation,
      statements: self,
      connection: connection,
      authorizer: authorizer,
      library: library
    )
  }

  func checkIn(_ statement: SQLitePreparedStatement, sql: String) {
    _ = library.pointee.reset(statement.pointer)
    _ = library.pointee.clear_bindings(statement.pointer)
    guard
      statement.cacheGeneration == generation,
      idle.count < capacity,
      idle[sql] == nil
    else {
      _ = library.pointee.finalize(statement.pointer)
      return
    }
    idle[sql] = statement
  }

  func invalidate() {
    generation &+= 1
    generatedColumnsByTable.removeAll()
    finalizeAll()
  }

  func generatedColumns(in table: String, schema: SQLiteSchemaName) -> Set<String>? {
    let table = Table(schema: schema, name: table.asciiLowercased)
    if let cached = generatedColumnsByTable[table] { return cached }
    guard let result = inspectGeneratedColumns(in: table.name, schema: table.schema) else {
      return nil
    }
    generatedColumnsByTable[table] = result
    return result
  }

  private func inspectGeneratedColumns(
    in table: String,
    schema: SQLiteSchemaName
  ) -> Set<String>? {
    let query: QueryFragment =
      """
      SELECT name
      FROM pragma_table_xinfo(\(bind: table), \(bind: schema.rawValue))
      WHERE hidden IN (2, 3)
      """
    let (sql, bindings) = prepareQuery(query)
    var statement: OpaquePointer?
    let code = sql.withCString {
      library.pointee.prepare_v3(connection, $0, -1, 0, &statement, nil)
    }
    guard code == SQLiteResultCode.ok.rawValue, let statement else { return nil }
    defer { _ = library.pointee.finalize(statement) }
    do {
      for (offset, binding) in bindings.enumerated() {
        try bind(binding, to: statement, at: Int32(offset + 1), library: library)
      }
    } catch {
      return nil
    }
    var columns: Set<String> = []
    while true {
      switch library.pointee.step(statement) {
      case SQLiteResultCode.done.rawValue:
        return columns
      case SQLiteResultCode.row.rawValue:
        guard let text = library.pointee.column_text(statement, 0) else { return nil }
        let count = Int(library.pointee.column_bytes(statement, 0))
        columns.insert(
          String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
            .asciiLowercased
        )
      default:
        return nil
      }
    }
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
  let invalidatesStatementCache: Bool
  let cacheGeneration: UInt64

  init(
    pointer: OpaquePointer,
    authorizations: [SQLiteAuthorization],
    cacheGeneration: UInt64 = 0,
    statements: SQLiteStatementCache?,
    connection: OpaquePointer,
    authorizer: SQLiteAuthorizerDispatcher?,
    library: UnsafePointer<SQLiteLibrary>
  ) {
    self.pointer = pointer
    self.cacheGeneration = cacheGeneration
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
      changedRegion.formUnion(
        authorization.changedRegion { table, schema in
          statements?.generatedColumns(in: table, schema: schema)
        }
      )
    }
    if changedRegion.isEmpty && library.pointee.stmt_readonly(pointer) == 0 {
      changedRegion = .fullDatabase
    }
    self.changedRegion = changedRegion
    self.invalidatesStatementCache = sqliteInvalidatesStatementCache(
      after: authorizations,
      statement: pointer,
      library: library
    )
  }
}

func sqliteInvalidatesStatementCache(
  after authorizations: [SQLiteAuthorization],
  statement: OpaquePointer,
  library: UnsafePointer<SQLiteLibrary>
) -> Bool {
  authorizations.contains(where: \.invalidatesStatementCache)
    || (library.pointee.stmt_readonly(statement) == 0
      && authorizations.contains { $0.action == .pragma })
}

extension SQLiteAuthorization {
  var invalidatesStatementCache: Bool {
    switch action {
    case .createIndex, .createTable, .createTemporaryIndex, .createTemporaryTable,
      .createTemporaryTrigger, .createTemporaryView, .createTrigger, .createView,
      .dropIndex, .dropTable, .dropTemporaryIndex, .dropTemporaryTable,
      .dropTemporaryTrigger, .dropTemporaryView, .dropTrigger, .dropView,
      .attach, .detach, .alterTable, .reindex, .analyze, .createVirtualTable,
      .dropVirtualTable:
      return true
    default:
      return false
    }
  }

  var changesFullDatabase: Bool {
    invalidatesStatementCache && action != .attach && action != .detach
  }

  func changedRegion(
    generatedColumns: (String, SQLiteSchemaName) -> Set<String>?
  ) -> OrbitDatabaseRegion {
    let schema = schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
    if changesFullDatabase { return .fullDatabase }
    switch action {
    case .delete, .insert:
      guard let table = firstArgument else { return .fullDatabase }
      return OrbitDatabaseRegion(table: table, schema: schema)
    case .update:
      guard let table = firstArgument, let column = secondArgument else { return .fullDatabase }
      guard let generatedColumns = generatedColumns(table, schema) else {
        return OrbitDatabaseRegion(table: table, schema: schema)
      }
      return OrbitDatabaseRegion(
        columns: generatedColumns.union([column]),
        in: table,
        schema: schema
      )
    default:
      return .empty
    }
  }
}
