// The prepared statements a connection keeps between uses. A statement is checked out while it
// runs, so two uses of the same SQL at once never share one, and checked back in afterwards. Up to
// `capacity` statements stay idle, and a full cache makes room by finalizing the one least
// recently checked in.
//
// The statement checked in last waits in a slot of its own rather than in the dictionary. A loop
// that runs one statement over and over, which is how most statements are reused, then finds it by
// comparing the query with that one statement's text, and gives it back, without hashing or
// touching the dictionary at all.
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

  // An idle statement, stamped with when it was last given back. A full cache makes room by
  // finalizing the statement with the oldest stamp, the one least recently used.
  private struct IdleStatement {
    let statement: SQLiteCompiledStatement
    let lastUse: UInt64
  }

  // The statement checked in most recently, kept apart from `idle` and never also in it. It counts
  // toward `capacity` like any other idle statement.
  private var hot: (key: SQLiteStatementCacheKey, entry: IdleStatement)?
  private var idle: [SQLiteStatementCacheKey: IdleStatement] = [:]
  private var useCount: UInt64 = 0
  // How many statements have ever been filed into `idle`, which only happens when one leaves the
  // hot slot. A loan remembers it, so a check-in can tell that nothing equal to its statement can
  // have reached the dictionary while it was out, and skip looking.
  private var idleInsertionCount: UInt64 = 0
  private(set) var generation: UInt64 = 0

  var idleStatementCount: Int { idle.count + (hot == nil ? 0 : 1) }

  // The schema version the cached statements were compiled under, or `nil` when that is unknown,
  // as it is before the first transaction and after this connection changes the schema itself.
  private var schemaVersion: Int64?
  private var schemaVersionStatement: OpaquePointer?
  private var isSchemaVersionUnavailable = false

  // The statements that control the connection, compiled on first use and kept until the
  // connection closes, indexed by `SQLiteControlStatement`.
  private var controlStatements = [OpaquePointer?](
    repeating: nil,
    count: SQLiteControlStatement.allCases.count
  )

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

  func prepare(_ sql: String, requiresReadOnly: Bool) throws -> SQLiteCompiledStatement? {
    try prepare(sql, flags: 0, requiresReadOnly: requiresReadOnly)
  }

  // Also returns the loan the statement is checked back in under, which carries the SQL's text: a
  // statement found in the cache brings its text along with it, so reusing a statement never joins
  // the query's text anew.
  func checkOut(
    _ query: SQL,
    requiresReadOnly: Bool
  ) throws -> (statement: SQLiteCompiledStatement?, loan: SQLiteStatementLoan) {
    // Taken out rather than copied, so a hit costs no retains, and put back on a miss.
    if let hot = hot.take() {
      if hot.key.matches(query) {
        return try lend(
          hot.entry.statement,
          filedUnder: hot.key,
          requiresReadOnly: requiresReadOnly
        )
      }
      self.hot = hot
    }
    return try checkOutFromIdle(query, requiresReadOnly: requiresReadOnly)
  }

  // A statement for a cursor or a prepared statement to run: lent by the cache when `cached` is
  // set, with the loan it goes back in under, or else compiled for its user alone. Also returns
  // the query's text, which a statement found in the cache brings along.
  func statement(
    for query: SQL,
    cached: Bool,
    requiresReadOnly: Bool
  ) throws -> (statement: SQLiteCompiledStatement?, loan: SQLiteStatementLoan?, sql: String) {
    guard cached else {
      let sql = query.text
      return (try prepare(sql, requiresReadOnly: requiresReadOnly), nil, sql)
    }
    let (statement, loan) = try checkOut(query, requiresReadOnly: requiresReadOnly)
    return (statement, loan, loan.sql)
  }

  // Gives back a statement from `statement(for:cached:requiresReadOnly:)`: checks it back in when
  // the cache lent it, and finalizes it otherwise.
  func giveBack(_ statement: SQLiteCompiledStatement, loan: SQLiteStatementLoan?) {
    if let loan {
      checkIn(statement, loan: loan)
    } else {
      _ = library.pointee.statements.execution.finalize(statement.pointer)
    }
  }

  private func checkOutFromIdle(
    _ query: SQL,
    requiresReadOnly: Bool
  ) throws -> (statement: SQLiteCompiledStatement?, loan: SQLiteStatementLoan) {
    let lookup = SQLiteStatementCacheKey(query)
    if let index = idle.index(forKey: lookup) {
      let (key, entry) = idle.remove(at: index)
      return try lend(entry.statement, filedUnder: key, requiresReadOnly: requiresReadOnly)
    }
    let sql = query.text
    let loan = SQLiteStatementLoan(
      key: SQLiteStatementCacheKey(filing: query, joinedInto: sql, lookedUpBy: lookup),
      idleInsertionCount: idleInsertionCount
    )
    // A cache that keeps nothing gains nothing from hinting that the statement will be reused.
    let statement = try prepare(
      sql,
      flags: capacity > 0 ? SQLitePrepareFlags.persistent.rawValue : 0,
      requiresReadOnly: requiresReadOnly
    )
    return (statement, loan)
  }

  private func lend(
    _ statement: SQLiteCompiledStatement,
    filedUnder key: SQLiteStatementCacheKey,
    requiresReadOnly: Bool
  ) throws -> (statement: SQLiteCompiledStatement?, loan: SQLiteStatementLoan) {
    let loan = SQLiteStatementLoan(key: key, idleInsertionCount: idleInsertionCount)
    guard !requiresReadOnly || statement.isReadOnly else {
      checkIn(statement, loan: loan)
      throw Self.mayWriteError(sql: loan.sql)
    }
    return (statement, loan)
  }

  private func prepare(
    _ sql: String,
    flags: UInt32,
    requiresReadOnly: Bool
  ) throws -> SQLiteCompiledStatement? {
    let (statement, authorizations) = try authorizer.recordingAuthorizations {
      try library.pointee.prepareStatement(sql, on: connection, flags: flags)
    }
    guard let statement else { return nil }
    let isReadOnly = library.pointee.statements.inspection.isReadOnly(statement) != 0
    guard !requiresReadOnly || isReadOnly else {
      _ = library.pointee.statements.execution.finalize(statement)
      throw Self.mayWriteError(sql: sql)
    }
    return SQLiteCompiledStatement(
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
  static func mayWriteError(sql: String) -> SQLiteError {
    SQLiteError(
      code: .readOnly,
      message: "a read-only query may write; run it in a write transaction instead",
      sql: sql
    )
  }

  func refreshedMetadata(for statement: OpaquePointer, sql: String) -> SQLiteCompiledStatement? {
    guard let probe = try? prepare(sql, flags: 0, requiresReadOnly: false) else { return nil }
    defer { _ = library.pointee.statements.execution.finalize(probe.pointer) }
    return SQLiteCompiledStatement(pointer: statement, metadata: probe)
  }

  func checkIn(_ statement: SQLiteCompiledStatement, loan: SQLiteStatementLoan) {
    _ = library.pointee.statements.execution.reset(statement.pointer)
    _ = library.pointee.statements.execution.clearBindings(statement.pointer)
    // Another use of the same SQL at once was lent a statement of its own, and whichever comes back
    // second finds the first already idle. Nothing reaches the dictionary except by leaving the hot
    // slot, so when nothing has left it since this statement went out, an equal one cannot be
    // there.
    guard
      statement.cacheGeneration == generation,
      capacity > 0,
      hot.map({ $0.key != loan.key }) ?? true,
      loan.idleInsertionCount == idleInsertionCount || idle[loan.key] == nil
    else {
      _ = library.pointee.statements.execution.finalize(statement.pointer)
      return
    }
    if idleStatementCount >= capacity {
      evictLeastRecentlyUsed()
    }
    if let hot {
      idle[hot.key] = hot.entry
      idleInsertionCount &+= 1
    }
    useCount &+= 1
    hot = (loan.key, IdleStatement(statement: statement, lastUse: useCount))
  }

  // A scan is enough: the cache is small, and this only runs when a statement the cache did not
  // hold comes back, which almost always means one was just compiled, at a far greater cost. The
  // hot statement is the most recently used, so it only goes when it is the only one left.
  private func evictLeastRecentlyUsed() {
    guard
      let oldest = idle.indices.min(by: { idle[$0].value.lastUse < idle[$1].value.lastUse })
    else {
      if let hot {
        _ = library.pointee.statements.execution.finalize(hot.entry.statement.pointer)
        self.hot = nil
      }
      return
    }
    let (_, evicted) = idle.remove(at: oldest)
    _ = library.pointee.statements.execution.finalize(evicted.statement.pointer)
  }

  func invalidate() {
    generation &+= 1
    // Statements compiled after this connection's own schema change are compiled against a schema
    // that a rollback can take back, so the version is only trusted again once it is read afresh.
    schemaVersion = nil
    finalizeIdle()
  }

  func invalidateAuthorization() {
    invalidate()
    if let schemaVersionStatement {
      _ = library.pointee.statements.execution.finalize(schemaVersionStatement)
      self.schemaVersionStatement = nil
    }
    isSchemaVersionUnavailable = false
    // A control statement was authorized when it was compiled, so it is compiled again under the
    // new policy rather than run under the old one's decision.
    finalizeControlStatements()
  }

  /// Runs one of the connection's control statements to completion, compiling it on first use.
  ///
  /// The statement is stepped through the library's step entry point, as any statement the
  /// connection executes is, and under the caller's authorization: SQLite authorizes it again
  /// whenever it recompiles one that a setting change has expired.
  ///
  /// - Throws: A ``SQLiteError`` naming the statement's SQL when it cannot be compiled or fails.
  func execute(_ control: SQLiteControlStatement) throws {
    let statement: OpaquePointer
    if let compiled = controlStatements[control.rawValue] {
      statement = compiled
    } else {
      // Fixed SQL holding one statement, so it never compiles to nothing.
      guard
        let compiled = try library.pointee.prepare(
          control.sql,
          on: connection,
          flags: SQLitePrepareFlags.persistent.rawValue
        )
      else { return }
      controlStatements[control.rawValue] = compiled
      statement = compiled
    }
    var code: Int32
    repeat {
      code = library.pointee.statements.execution.step(statement)
    } while code == SQLiteResultCode.row.rawValue
    guard code == SQLiteResultCode.done.rawValue else {
      let error = SQLiteError.reported(
        by: library.pointee,
        on: connection,
        code: code,
        sql: control.sql
      )
      if control.isFlagPragma {
        // A flag pragma takes effect as it compiles, and its program expires every statement, itself
        // included, so that it compiles again on its next step. One that failed before its program
        // ran is not expired, and would set nothing the next time, so it is compiled afresh.
        _ = library.pointee.statements.execution.finalize(statement)
        controlStatements[control.rawValue] = nil
      } else {
        _ = library.pointee.statements.execution.reset(statement)
      }
      throw error
    }
    _ = library.pointee.statements.execution.reset(statement)
  }

  private func finalizeControlStatements() {
    for index in controlStatements.indices {
      guard let statement = controlStatements[index] else { continue }
      _ = library.pointee.statements.execution.finalize(statement)
      controlStatements[index] = nil
    }
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

  func changedRegion(after authorizations: [SQLiteRawAuthorization]) -> OrbitDatabaseRegion {
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
    finalizeControlStatements()
  }

  private func finalizeIdle() {
    if let hot {
      _ = library.pointee.statements.execution.finalize(hot.entry.statement.pointer)
      self.hot = nil
    }
    for entry in idle.values {
      _ = library.pointee.statements.execution.finalize(entry.statement.pointer)
    }
    idle.removeAll()
  }
}

/// A statement the connection runs to control itself rather than for the application: beginning
/// and ending transactions, and switching `query_only`. Each is kept compiled for the life of the
/// connection, since every access runs some of them.
enum SQLiteControlStatement: Int, CaseIterable {
  case beginDeferred
  case beginImmediate
  case beginExclusive
  case beginConcurrent
  case commit
  case rollback
  case queryOnly
  case writable

  var sql: String {
    switch self {
    case .beginDeferred: "BEGIN DEFERRED TRANSACTION"
    case .beginImmediate: "BEGIN IMMEDIATE TRANSACTION"
    case .beginExclusive: "BEGIN EXCLUSIVE TRANSACTION"
    case .beginConcurrent: "BEGIN CONCURRENT TRANSACTION"
    case .commit: "COMMIT"
    case .rollback: "ROLLBACK"
    // Numeric booleans are accepted by both SQLite and Turso. Turso currently parses the `ON`
    // keyword as a different expression kind than the pragma implementation accepts.
    case .queryOnly: "PRAGMA query_only = 1"
    case .writable: "PRAGMA query_only = 0"
    }
  }

  var isFlagPragma: Bool {
    switch self {
    case .queryOnly, .writable: true
    default: false
    }
  }
}

// What a statement lent by the cache is checked back in under: the key it is filed under, which
// carries the SQL's text and its hash, so giving a statement back never hashes the text again.
struct SQLiteStatementLoan {
  let key: SQLiteStatementCacheKey

  // The cache's `idleInsertionCount` when the statement went out, when no statement equal to it
  // was idle in the dictionary.
  let idleInsertionCount: UInt64

  var sql: String { key.text }
}

// A cached statement is filed under its SQL's text, and found again from the query's parts, so
// a query that is run again is not joined into text just to look its statement up. Both compare
// as the UTF-8 the statement was compiled from, byte for byte.
struct SQLiteStatementCacheKey: Hashable {
  private enum Source {
    case text(String)
    case query(SQL)
  }

  private let source: Source

  // Worked out once, when the key is made, so a key carried from check-out to check-in, or moved
  // out of the hot slot into the dictionary, is never hashed again.
  private let hash: Int

  // The pieces of the query whose statement is filed under this key, kept so that the same query
  // run again, built from the very same strings, is recognized without reading its text.
  private let pieces: [SQL.Part]?

  init(_ text: String) {
    source = .text(text)
    pieces = nil
    hash = text.withUTF8Bytes { bytes in
      var hasher = Hasher()
      hasher.combine(bytes: bytes)
      return hasher.finalize()
    }
  }

  init(_ query: SQL) {
    source = .query(query)
    pieces = nil
    hash = Self.hash(query)
  }

  // The key a query's statement is filed under, made from the text `query` was joined into and
  // the key it was looked up by, so the text is not hashed again.
  init(filing query: SQL, joinedInto text: String, lookedUpBy key: Self) {
    source = .text(text)
    pieces = query.textPieces
    hash = key.hash
  }

  var text: String {
    switch source {
    case .text(let text): text
    case .query(let query): query.text
    }
  }

  // Hashing is a byte stream, so a query's pieces hash as their joined text does.
  private static func hash(_ query: SQL) -> Int {
    var hasher = Hasher()
    _ = query.forEachTextChunk { chunk in
      hasher.combine(bytes: chunk)
      return true
    }
    return hasher.finalize()
  }

  private func forEachChunk(_ body: (UnsafeRawBufferPointer) -> Bool) -> Bool {
    switch source {
    case .text(let text): text.withUTF8Bytes(body)
    case .query(let query): query.forEachTextChunk(body)
    }
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(hash)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.hash == rhs.hash else { return false }
    switch (lhs.source, rhs.source) {
    case (.text(let text), _):
      return text.withUTF8Bytes { rhs.matches($0) }
    case (_, .text(let text)):
      return text.withUTF8Bytes { lhs.matches($0) }
    case (.query(let query), _):
      // Only text is ever stored, so two queries are never compared in the cache itself.
      return query.text.withUTF8Bytes { rhs.matches($0) }
    }
  }

  // Whether `query` joins into this key's text, found without hashing either.
  func matches(_ query: SQL) -> Bool {
    if let pieces, query.hasTextIdentical(to: pieces) { return true }
    return text.withUTF8Bytes { bytes in Self.chunks({ query.forEachTextChunk($0) }, match: bytes) }
  }

  private func matches(_ bytes: UnsafeRawBufferPointer) -> Bool {
    Self.chunks({ forEachChunk($0) }, match: bytes)
  }

  private static func chunks(
    _ forEachChunk: ((UnsafeRawBufferPointer) -> Bool) -> Bool,
    match bytes: UnsafeRawBufferPointer
  ) -> Bool {
    var offset = 0
    let matchedEveryChunk = forEachChunk { chunk in
      guard chunk.count <= bytes.count - offset else { return false }
      let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + chunk.count])
      offset += chunk.count
      return slice.hasSameBytes(as: chunk)
    }
    return matchedEveryChunk && offset == bytes.count
  }
}

// A statement SQLite compiled, with what was learned about it while it compiled: the regions it
// reads and changes, and whether it controls transactions or invalidates the cache. Named apart
// from the public `SQLitePreparedStatement`, which holds one of these for a caller to run again.
struct SQLiteCompiledStatement {
  let pointer: OpaquePointer
  let controlsTransactions: Bool
  let readRegion: OrbitDatabaseRegion
  let changedRegion: OrbitDatabaseRegion
  let invalidatesStatementCache: Bool
  let cacheGeneration: UInt64

  // `sqlite3_stmt_readonly`, which is what a read transaction is refused a statement by.
  let isReadOnly: Bool

  init(pointer: OpaquePointer, metadata: Self) {
    self.pointer = pointer
    self.controlsTransactions = metadata.controlsTransactions
    self.isReadOnly = metadata.isReadOnly
    self.readRegion = metadata.readRegion
    self.changedRegion = metadata.changedRegion
    self.invalidatesStatementCache = metadata.invalidatesStatementCache
    self.cacheGeneration = metadata.cacheGeneration
  }

  init(
    pointer: OpaquePointer,
    isReadOnly: Bool,
    authorizations: [SQLiteRawAuthorization],
    cacheGeneration: UInt64 = 0,
    statements: SQLiteStatementCache?,
    connection: OpaquePointer,
    authorizer: SQLiteAuthorizerDispatcher?,
    library: UnsafePointer<SQLiteLibrary>
  ) {
    self.pointer = pointer
    self.controlsTransactions = authorizations.contains {
      $0.action == .transaction || $0.action == .savepoint
    }
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
  after authorizations: [SQLiteRawAuthorization],
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

extension SQLiteRawAuthorization {
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

  // Worked out only for the actions that change a table, rather than for every read.
  private var schema: SQLiteSchemaName {
    schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
  }
}
