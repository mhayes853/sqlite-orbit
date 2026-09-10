import StructuredQueries

final class SQLiteStatementCache {
  private struct Table: Hashable {
    let schema: SQLiteSchemaName
    let name: String
  }

  private enum TableUpdateScope {
    case columns(Set<String>)
    case table
  }

  private let library: UnsafePointer<SQLiteLibrary>
  private let connection: OpaquePointer
  private let authorizer: SQLiteAuthorizerDispatcher
  private let capacity: Int

  private var idle: [String: SQLitePreparedStatement] = [:]
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
        library.pointee.statement.prepare(connection, $0, -1, flags, &statement, nil)
      }
    }
    guard code == SQLiteResultCode.ok.rawValue, let statement else {
      if let statement {
        _ = library.pointee.statement.finalize(statement)
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

  func refreshedMetadata(for statement: OpaquePointer, sql: String) -> SQLitePreparedStatement? {
    guard let probe = try? prepare(sql, flags: 0) else { return nil }
    defer { _ = library.pointee.statement.finalize(probe.pointer) }
    return SQLitePreparedStatement(pointer: statement, metadata: probe)
  }

  func checkIn(_ statement: SQLitePreparedStatement, sql: String) {
    _ = library.pointee.statement.reset(statement.pointer)
    _ = library.pointee.statement.clearBindings(statement.pointer)
    guard
      statement.cacheGeneration == generation,
      idle.count < capacity,
      idle[sql] == nil
    else {
      _ = library.pointee.statement.finalize(statement.pointer)
      return
    }
    idle[sql] = statement
  }

  func invalidate() {
    generation &+= 1
    finalizeAll()
  }

  func changedRegion(after authorizations: [SQLiteAuthorization]) -> OrbitDatabaseRegion {
    var scopes: [Table: TableUpdateScope] = [:]
    var region = OrbitDatabaseRegion.empty
    for authorization in authorizations {
      region.formUnion(
        authorization.changedRegion { table, schema in
          let table = Table(schema: schema, name: table.asciiLowercased)
          let scope =
            scopes[table] ?? inspectUpdateScope(in: table.name, schema: table.schema)
            ?? .table
          scopes[table] = scope
          guard case .columns(let columns) = scope else { return nil }
          return columns
        }
      )
    }
    return region
  }

  private func inspectUpdateScope(
    in table: String,
    schema: SQLiteSchemaName
  ) -> TableUpdateScope? {
    let query: QueryFragment =
      """
      SELECT
        info.name,
        info.hidden,
        coalesce(upper(ltrim(tables.sql)) GLOB 'CREATE VIRTUAL TABLE *', 0)
      FROM pragma_table_xinfo(\(bind: table), \(bind: schema.rawValue)) AS info
      LEFT JOIN \(quote: schema.rawValue).sqlite_schema AS tables
        ON tables.type = 'table' AND tables.name = \(bind: table) COLLATE NOCASE
      """
    let (sql, bindings) = prepareQuery(query)
    var statement: OpaquePointer?
    let code = sql.withCString {
      library.pointee.statement.prepare(connection, $0, -1, 0, &statement, nil)
    }
    guard code == SQLiteResultCode.ok.rawValue, let statement else { return nil }
    defer { _ = library.pointee.statement.finalize(statement) }
    do {
      for (offset, binding) in bindings.enumerated() {
        try bind(binding, to: statement, at: Int32(offset + 1), library: library)
      }
    } catch {
      return nil
    }
    var columns: Set<String> = []
    while true {
      switch library.pointee.statement.step(statement) {
      case SQLiteResultCode.done.rawValue:
        return .columns(columns)
      case SQLiteResultCode.row.rawValue:
        if library.pointee.column.int64(statement, 2) != 0 { return .table }

        let hidden = library.pointee.column.int64(statement, 1)
        guard hidden == 2 || hidden == 3 else { continue }
        guard let text = library.pointee.column.text(statement, 0) else { return nil }
        let count = Int(library.pointee.column.byteCount(statement, 0))
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
      _ = library.pointee.statement.finalize(statement.pointer)
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

  init(pointer: OpaquePointer, metadata: Self) {
    self.pointer = pointer
    self.readRegion = metadata.readRegion
    self.changedRegion = metadata.changedRegion
    self.invalidatesStatementCache = metadata.invalidatesStatementCache
    self.cacheGeneration = metadata.cacheGeneration
  }

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
    var changedRegion =
      statements?.changedRegion(after: authorizations)
      ?? authorizations.reduce(into: OrbitDatabaseRegion.empty) { region, authorization in
        region.formUnion(authorization.changedRegion { _, _ in nil })
      }
    if changedRegion.isEmpty && library.pointee.statement.isReadOnly(pointer) == 0 {
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
  // Without an authorizer there is no safe way to distinguish DDL and connection-changing
  // pragmas from ordinary mutations. Invalidating after every write is broader but correct.
  if authorizations.isEmpty { return library.pointee.statement.isReadOnly(statement) == 0 }
  return authorizations.contains(where: \.invalidatesStatementCache)
    || (library.pointee.statement.isReadOnly(statement) == 0
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
    additionalColumnsAffectedByUpdate: (String, SQLiteSchemaName) -> Set<String>?
  ) -> OrbitDatabaseRegion {
    let schema = schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
    if changesFullDatabase { return .fullDatabase }
    switch action {
    case .delete, .insert:
      guard let table = firstArgument else { return .fullDatabase }
      return OrbitDatabaseRegion(table: table, schema: schema)
    case .update:
      guard let table = firstArgument, let column = secondArgument else { return .fullDatabase }
      guard let additionalColumns = additionalColumnsAffectedByUpdate(table, schema) else {
        return OrbitDatabaseRegion(table: table, schema: schema)
      }
      return OrbitDatabaseRegion(
        columns: additionalColumns.union([column]),
        in: table,
        schema: schema
      )
    default:
      return .empty
    }
  }
}
