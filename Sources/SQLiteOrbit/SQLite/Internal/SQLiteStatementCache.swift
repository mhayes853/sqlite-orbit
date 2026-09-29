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
  private(set) var generation: UInt64 = 0

  // The schema version the cached statements were compiled under, or `nil` when that is unknown,
  // as it is before the first transaction and after this connection changes the schema itself.
  private var schemaVersion: Int64?
  private var schemaVersionStatement: OpaquePointer?
  private var isSchemaVersionUnavailable = false

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

  // Each of these compiles a caller's SQL, and returns `nil` for SQL that holds no statement, such
  // as an empty query. A statement that may write is refused when `requiresReadOnly` is set, before
  // anything is derived from it.

  func prepare(_ sql: String, requiresReadOnly: Bool) throws -> SQLitePreparedStatement? {
    try prepare(sql, flags: 0, requiresReadOnly: requiresReadOnly)
  }

  func checkOut(_ sql: String, requiresReadOnly: Bool) throws -> SQLitePreparedStatement? {
    if let statement = idle.removeValue(forKey: sql) {
      guard !requiresReadOnly || statement.isReadOnly else {
        checkIn(statement, sql: sql)
        throw Self.mayWriteError(sql: sql)
      }
      return statement
    }
    // A cache that keeps nothing gains nothing from hinting that the statement will be reused.
    return try prepare(
      sql,
      flags: capacity > 0 ? SQLitePrepareFlags.persistent.rawValue : 0,
      requiresReadOnly: requiresReadOnly
    )
  }

  private func prepare(
    _ sql: String,
    flags: UInt32,
    requiresReadOnly: Bool
  ) throws -> SQLitePreparedStatement? {
    let (statement, authorizations) = try authorizer.recordingAuthorizations {
      try library.pointee.prepareStatement(sql, on: connection, flags: flags)
    }
    guard let statement else { return nil }
    let isReadOnly = library.pointee.statements.inspection.isReadOnly(statement) != 0
    guard !requiresReadOnly || isReadOnly else {
      _ = library.pointee.statements.execution.finalize(statement)
      throw Self.mayWriteError(sql: sql)
    }
    return SQLitePreparedStatement(
      pointer: statement,
      isReadOnly: isReadOnly,
      authorizations: authorizations,
      cacheGeneration: generation,
      statements: self,
      connection: connection,
      authorizer: authorizer,
      library: library
    )
  }

  // Raw SQL cannot show through its type that it only reads, so a read-only access holds each
  // statement to it when it is compiled, before anything has run.
  private static func mayWriteError(sql: String) -> SQLiteError {
    SQLiteError(
      code: .readOnly,
      message: "a read-only query may write; run it in a write transaction instead",
      sql: sql
    )
  }

  func refreshedMetadata(for statement: OpaquePointer, sql: String) -> SQLitePreparedStatement? {
    guard let probe = try? prepare(sql, flags: 0, requiresReadOnly: false) else { return nil }
    defer { _ = library.pointee.statements.execution.finalize(probe.pointer) }
    return SQLitePreparedStatement(pointer: statement, metadata: probe)
  }

  func checkIn(_ statement: SQLitePreparedStatement, sql: String) {
    _ = library.pointee.statements.execution.reset(statement.pointer)
    _ = library.pointee.statements.execution.clearBindings(statement.pointer)
    guard
      statement.cacheGeneration == generation,
      idle.count < capacity,
      idle[sql] == nil
    else {
      _ = library.pointee.statements.execution.finalize(statement.pointer)
      return
    }
    idle[sql] = statement
  }

  func invalidate() {
    generation &+= 1
    // Statements compiled after this connection's own schema change are compiled against a schema
    // that a rollback can take back, so the version is only trusted again once it is read afresh.
    schemaVersion = nil
    finalizeIdle()
  }

  /// Drops the cached statements when another connection has changed the schema since they were
  /// compiled.
  ///
  /// This runs at the start of every transaction, so the version read belongs to the transaction's
  /// snapshot. SQLite recompiles a stale statement on its own, but the regions cached beside it
  /// describe the schema it was compiled against. Until something steps into the changed schema,
  /// the connection also keeps compiling new statements, and deriving regions from queries,
  /// against its old copy. A view redefined by a pool's writer or by another process would
  /// otherwise leave this connection tracking tables the view no longer reads.
  func invalidateIfSchemaChanged() {
    guard !isSchemaVersionUnavailable else { return }
    guard let version = readSchemaVersion() else {
      // An unreadable version cannot vouch for the cache, so it is dropped rather than trusted.
      invalidate()
      return
    }
    guard version != schemaVersion else { return }
    invalidate()
    reloadSchema()
    schemaVersion = version
  }

  private func readSchemaVersion() -> Int64? {
    // The pragma is compiled once per connection, so an unchanged schema costs a single step. It
    // is compiled and stepped outside of any authorization recording, so it is never reported to
    // observers as a read.
    if schemaVersionStatement == nil {
      let statement = try? library.pointee.prepare(
        "PRAGMA schema_version",
        on: connection,
        flags: SQLitePrepareFlags.persistent.rawValue
      )
      guard let statement else {
        // A build without the pragma keeps relying on SQLite recompiling a stale statement, which
        // the cursor notices on its first step.
        isSchemaVersionUnavailable = true
        return nil
      }
      schemaVersionStatement = statement
    }
    guard let statement = schemaVersionStatement else { return nil }
    defer { _ = library.pointee.statements.execution.reset(statement) }
    switch library.pointee.statements.execution.step(statement) {
    case SQLiteResultCode.row.rawValue:
      return library.pointee.columns.int64(statement, 0)
    case SQLiteResultCode.done.rawValue:
      // A build that accepts the pragma but reports nothing would otherwise empty the cache on
      // every transaction.
      isSchemaVersionUnavailable = true
      return nil
    default:
      return nil
    }
  }

  private func reloadSchema() {
    // Compiling only consults the connection's in-memory copy of the schema, and nothing replaces
    // that copy until a statement steps into the schema cookie that changed. Stepping one here
    // means the statements the cache compiles next, and the regions derived from queries, see the
    // schema this transaction reads rather than the one the connection last loaded.
    let statement = try? library.pointee.prepare(
      "SELECT 1 FROM sqlite_schema LIMIT 0",
      on: connection
    )
    guard let statement else { return }
    defer { _ = library.pointee.statements.execution.finalize(statement) }
    _ = library.pointee.statements.execution.step(statement)
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
    let query: SQL = """
      SELECT
        info.name,
        info.hidden,
        coalesce(upper(ltrim(tables.sql)) GLOB 'CREATE VIRTUAL TABLE *', 0)
      FROM pragma_table_xinfo(\(table), \(schema.rawValue)) AS info
      LEFT JOIN \(quote: schema.rawValue).sqlite_schema AS tables
        ON tables.type = 'table' AND tables.name = \(table) COLLATE NOCASE
      """
    guard let statement = try? library.pointee.prepare(query.text, on: connection) else {
      return nil
    }
    defer { _ = library.pointee.statements.execution.finalize(statement) }
    do {
      try bind(query, to: statement, library: library)
    } catch {
      return nil
    }
    var columns: Set<String> = []
    while true {
      switch library.pointee.statements.execution.step(statement) {
      case SQLiteResultCode.done.rawValue:
        return .columns(columns)
      case SQLiteResultCode.row.rawValue:
        if library.pointee.columns.int64(statement, 2) != 0 { return .table }

        let hidden = library.pointee.columns.int64(statement, 1)
        guard hidden == 2 || hidden == 3 else { continue }
        guard let text = library.pointee.columns.text(statement, 0) else { return nil }
        let count = Int(library.pointee.columns.byteCount(statement, 0))
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
    finalizeIdle()
    if let schemaVersionStatement {
      _ = library.pointee.statements.execution.finalize(schemaVersionStatement)
      self.schemaVersionStatement = nil
    }
  }

  private func finalizeIdle() {
    for statement in idle.values {
      _ = library.pointee.statements.execution.finalize(statement.pointer)
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

  // `sqlite3_stmt_readonly`, which is what a read transaction is refused a statement by.
  let isReadOnly: Bool

  init(pointer: OpaquePointer, metadata: Self) {
    self.pointer = pointer
    self.isReadOnly = metadata.isReadOnly
    self.readRegion = metadata.readRegion
    self.changedRegion = metadata.changedRegion
    self.invalidatesStatementCache = metadata.invalidatesStatementCache
    self.cacheGeneration = metadata.cacheGeneration
  }

  init(
    pointer: OpaquePointer,
    isReadOnly: Bool,
    authorizations: [SQLiteAuthorization],
    cacheGeneration: UInt64 = 0,
    statements: SQLiteStatementCache?,
    connection: OpaquePointer,
    authorizer: SQLiteAuthorizerDispatcher?,
    library: UnsafePointer<SQLiteLibrary>
  ) {
    self.pointer = pointer
    self.cacheGeneration = cacheGeneration
    self.isReadOnly = isReadOnly
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
    if changedRegion.isEmpty && !isReadOnly {
      changedRegion = .fullDatabase
    }
    self.changedRegion = changedRegion
    self.invalidatesStatementCache = sqliteInvalidatesStatementCache(
      after: authorizations,
      isReadOnly: isReadOnly
    )
  }
}

// `isReadOnly` is what `sqlite3_stmt_readonly` reports for the statement.
func sqliteInvalidatesStatementCache(
  after authorizations: [SQLiteAuthorization],
  isReadOnly: Bool
) -> Bool {
  // Without an authorizer there is no safe way to distinguish DDL and connection-changing
  // pragmas from ordinary mutations. Invalidating after every write is broader but correct.
  if authorizations.isEmpty {
    return !isReadOnly
  }
  return authorizations.contains(where: \.invalidatesStatementCache)
    || (!isReadOnly && authorizations.contains { $0.action == .pragma })
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

  func changedRegion(
    additionalColumnsAffectedByUpdate: (String, SQLiteSchemaName) -> Set<String>?
  ) -> OrbitDatabaseRegion {
    let schema = schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
    // Schema changes may have changed anything. Attaching and detaching a database are the two
    // that do not: they bring a schema along or take it away rather than rewrite one.
    if invalidatesStatementCache, action != .attach, action != .detach { return .fullDatabase }
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
