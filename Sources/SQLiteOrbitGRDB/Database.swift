#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  private struct DatabaseRollback: Error {}

  public final class Database {
    public enum TransactionCompletion: Sendable {
      case commit, rollback
    }

    public enum TransactionKind: String, Sendable {
      case deferred = "DEFERRED"
      case immediate = "IMMEDIATE"
      case exclusive = "EXCLUSIVE"
    }

    public enum ConflictResolution: String, Sendable {
      case rollback, abort, fail, ignore, replace
    }

    let access: SQLiteScopedAccess
    var _connectionState: DatabaseConnectionState?
    // When set, accumulates the regions read by the statements of this database.
    var regionRecorder: DatabaseRegion?
    // Raw read statements, finalized by the access wrapper that enabled them.
    var rawStatements: RawStatementList?
    var transactionWasOpen = false

    init(_ access: SQLiteScopedAccess) {
      self.access = access
    }

    public var sqliteConnection: OpaquePointer? {
      checked { try access.sqliteConnection }
    }

    public var changesCount: Int {
      checked { try access.changesCount }
    }

    public var totalChangesCount: Int {
      checked { try untracedTotalChanges() }
    }

    public var lastInsertedRowID: Int64 {
      checked { try access.lastInsertedRowID }
    }

    public var isInsideTransaction: Bool {
      checked { try access.isInsideTransaction }
    }

    private func checked<T>(_ body: () throws -> T) -> T {
      do {
        return try body()
      } catch {
        preconditionFailure(String(describing: error))
      }
    }

    public func execute(sql: String, arguments: StatementArguments = StatementArguments()) throws {
      try translate {
        var remaining = sql
        var arguments = arguments
        while true {
          let part = try access.firstStatement(remaining)
          guard let text = part.statement else {
            break
          }
          let bound = try bindArguments(arguments, sql: text, allowRemaining: true)
          let cursor = try access.statementCursor(
            SQLiteOrbit.SQL(text: text, bindings: bound.values.map(\.orbitValue))
          )
          let trace = traceStatement(sql: text, values: bound.values)
          do {
            while try cursor.next() != nil {}
          } catch let error as SQLiteError {
            throw statementError(error, values: bound.values)
          }
          trace?.finish()
          arguments.consume(bound.consumed)
          remaining = part.remainder
        }
        if !isInsideTransaction {
          deliverRegionChanges()
        }
        if !arguments.values.isEmpty {
          throw DatabaseError(
            resultCode: .SQLITE_MISUSE,
            message: "unused statement arguments",
            sql: sql,
            arguments: arguments
          )
        }
      }
    }

    public func execute(literal: SQL) throws {
      let (sql, arguments) = try literal.build(self)
      try execute(sql: sql, arguments: arguments)
    }

    public func makeStatement(sql: String) throws -> Statement {
      try Statement(database: self, sql: singleStatement(sql), cached: false)
    }

    // Returns the only statement in `sql`, refusing empty SQL and multiple statements as GRDB does.
    func singleStatement(_ sql: String) throws -> String {
      let (statement, remainder) = try translate { try access.firstStatement(sql) }
      guard let statement else {
        throw DatabaseError(resultCode: .SQLITE_ERROR, message: "empty statement", sql: sql)
      }
      let hasMore = (try? access.firstStatement(remainder).statement != nil) ?? true
      if hasMore {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: """
            Multiple statements found. To execute multiple statements, use \
            Database.execute(sql:) or Database.allStatements(sql:) instead.
            """,
          sql: sql
        )
      }
      return statement
    }

    /// An error raised while running a statement, carrying its arguments as GRDB reports them.
    func statementError(_ error: SQLiteError, values: [DatabaseValue]) -> DatabaseError {
      DatabaseError(
        error,
        arguments: StatementArguments(values),
        publicStatementArguments: connectionState.publicStatementArguments
      )
    }

    public func makeStatement(literal: SQL) throws -> Statement {
      let (sql, arguments) = try literal.build(self)
      let statement = try makeStatement(sql: sql)
      statement.arguments = arguments
      return statement
    }

    public func cachedStatement(sql: String) throws -> Statement {
      try Statement(database: self, sql: singleStatement(sql), cached: true)
    }

    public func cachedStatement(literal: SQL) throws -> Statement {
      let (sql, arguments) = try literal.build(self)
      let statement = try cachedStatement(sql: sql)
      statement.arguments = arguments
      return statement
    }

    public func inTransaction(
      _ kind: TransactionKind? = nil,
      _ body: () throws -> TransactionCompletion
    ) throws {
      let kind = kind ?? .immediate
      let mode: SQLiteWriteTransactionMode =
        switch kind {
        case .deferred: .deferred
        case .immediate: .immediate
        case .exclusive: .exclusive
        }
      var committed = false
      connectionState.transactionDate = nil
      defer {
        connectionState.transactionDate = nil
        connectionState.transactionDidEnd(self, committed: committed)
      }
      try translate {
        traceTransactionStatement("BEGIN \(kind.rawValue) TRANSACTION")
        do {
          try access.transaction(mode: mode) { _ in
            if try body() == .rollback {
              throw DatabaseRollback()
            }
          }
          traceTransactionStatement("COMMIT TRANSACTION")
          committed = true
          deliverRegionChanges()
        } catch is DatabaseRollback {
          traceTransactionStatement("ROLLBACK TRANSACTION")
        } catch {
          traceTransactionStatement("ROLLBACK TRANSACTION")
          throw error
        }
      }
    }

    /// Runs `body` in a savepoint, or in a transaction outside of one. As in GRDB, nested
    /// savepoints share the name `grdb`.
    public func inSavepoint(_ body: () throws -> TransactionCompletion) throws {
      if !isInsideTransaction {
        return try inTransaction(nil, body)
      }
      try execute(sql: "SAVEPOINT grdb")
      var firstError: (any Error)?
      var needsRollback = false
      do {
        if try body() == .commit {
          try execute(sql: "RELEASE SAVEPOINT grdb")
        } else {
          needsRollback = true
        }
      } catch {
        firstError = error
        needsRollback = true
      }
      if needsRollback {
        do {
          try execute(sql: "ROLLBACK TRANSACTION TO SAVEPOINT grdb")
          try execute(sql: "RELEASE SAVEPOINT grdb")
        } catch {
          if firstError == nil { firstError = error }
        }
      }
      if let firstError {
        throw firstError
      }
    }

    /// Registers closures that run when the next transaction managed by this overlay ends.
    ///
    /// Only transactions started with `inTransaction`, `inSavepoint` outside a transaction, or
    /// the writers' `write` methods are observed; raw transaction SQL is refused by SQLiteOrbit.
    public func afterNextTransaction(
      onCommit: @escaping (Database) -> Void,
      onRollback: @escaping (Database) -> Void = { _ in }
    ) {
      connectionState.afterNextTransaction.append((onCommit, onRollback))
    }

    #if BuiltInSQLite
      /// The version number of the built-in SQLite library.
      public static var sqliteLibVersionNumber: CInt {
        SQLiteConfiguration.default.library.runtime.versionNumber()
      }
    #endif

    /// The configuration of the database that opened this connection.
    public var configuration: Configuration {
      connectionState.configuration
        ?? Configuration(native: checked { try access.configuration }, readerCount: 1)
    }

    /// Runs `value` while the connection refuses writes, with `PRAGMA query_only`.
    public func readOnly<T>(_ value: () throws -> T) throws -> T {
      func pragma(_ sql: String) throws -> Bool? {
        try translate {
          let cursor = try access.statementCursor(SQLiteOrbit.SQL(text: sql, bindings: []))
          defer { try? cursor.close() }
          return try cursor.next()?.first.map { DatabaseValue($0.value) }
            .flatMap(Bool.fromDatabaseValue)
        }
      }
      if try pragma("PRAGMA query_only") == true {
        return try value()
      }
      _ = try pragma("PRAGMA query_only = 1")
      defer { _ = try? pragma("PRAGMA query_only = 0") }
      return try value()
    }

    /// Whether the connection currently refuses writes.
    var isReadOnly: Bool {
      (try? Bool.fetchOne(self, sql: "PRAGMA query_only")) == true
    }

    /// The function a busy connection calls to decide whether to retry.
    public typealias BusyCallback = @Sendable (_ numberOfTries: Int) -> Bool

    func cursor(
      sql: String,
      arguments: StatementArguments,
      cached: Bool = false,
      unchecked: Bool = false,
      adapter: (any RowAdapter)? = nil
    ) throws -> RowCursor {
      try translate {
        let bound = try bindArguments(
          arguments,
          sql: sql,
          allowRemaining: unchecked,
          allowMissing: unchecked
        )
        let source: RowCursor.Source
        if let raw = try rawSelect(sql: sql, values: bound.values) {
          source = .raw(raw)
        } else {
          source = .native(
            try access.statementCursor(
              SQLiteOrbit.SQL(text: sql, bindings: bound.values.map(\.orbitValue)),
              cached: cached
            )
          )
        }
        do {
          let rows = try RowCursor(source, sql: sql, arguments: arguments, adapter: adapter)
          rows.trace = { [weak self] in self?.traceStatement(sql: sql, values: bound.values) }
          rows.boundValues = bound.values
          if let recorded = regionRecorder {
            regionRecorder = recorded.union(rows.databaseRegion)
          }
          rows.publicStatementArguments = connectionState.publicStatementArguments
          return rows
        } catch {
          source.close()
          throw error
        }
      }
    }

    // Read-only queries run on raw statements in accesses that finalize them before returning,
    // which avoids SQLiteOrbit's owned row copies. Other statements use native cursors.
    private func rawSelect(sql: String, values: [DatabaseValue]) throws -> RawSelectStatement? {
      guard let rawStatements else { return nil }
      let keyword = sql.drop { $0.isWhitespace }.prefix(6).uppercased()
      guard keyword.hasPrefix("SELECT") || keyword.hasPrefix("WITH") || keyword.hasPrefix("VALUES")
      else { return nil }
      if transactionWasOpen, !(try access.isInsideTransaction) {
        throw SQLiteError(
          code: SQLiteResultCode(rawValue: 4),
          message: "transaction was aborted",
          sql: sql
        )
      }
      let info = try access.statementInfo(sql)
      guard info.isReadOnly, info.parameterCount == values.count else { return nil }
      let raw = try RawSelectStatement(access: access, sql: sql, values: values, region: info)
      rawStatements.append(raw)
      return raw
    }

    // Enables raw statements; `finalizeRawStatements` must run before the access ends.
    func enableRawStatements() {
      rawStatements = RawStatementList()
      transactionWasOpen = (try? access.isInsideTransaction) ?? false
    }

    func finalizeRawStatements() {
      rawStatements?.finalizeAll()
      rawStatements = nil
    }
  }

  final class RawStatementList {
    private var statements: [RawSelectStatement] = []

    func append(_ statement: RawSelectStatement) {
      statements.removeAll { $0.isFinalized }
      statements.append(statement)
    }

    func finalizeAll() {
      for statement in statements { statement.finalize() }
      statements = []
    }
  }

  // A prepared read-only statement stepped directly through the library's function table.
  final class RawSelectStatement {
    private let access: SQLiteScopedAccess
    private let library: SQLiteLibrary
    private let connection: OpaquePointer
    private var pointer: OpaquePointer?
    private let sql: String
    private let readRegion: OrbitDatabaseRegion
    private var published = false
    let columnNames: [String]

    var isFinalized: Bool { pointer == nil }
    var region: OrbitDatabaseRegion { readRegion }

    init(
      access: SQLiteScopedAccess,
      sql: String,
      values: [DatabaseValue],
      region: SQLiteStatementInfo
    )
      throws
    {
      self.access = access
      self.sql = sql
      library = try access.configuration.library
      connection = try access.sqliteConnection
      readRegion = region.readRegion
      columnNames = region.columnNames
      var statement: OpaquePointer?
      let code = sql.withCString {
        library.statements.preparation.prepare(connection, $0, -1, 0, &statement, nil)
      }
      guard code == 0, let statement else {
        if let statement { _ = library.statements.execution.finalize(statement) }
        throw error(code)
      }
      pointer = statement
      for (offset, value) in values.enumerated() {
        let index = Int32(offset + 1)
        let code: Int32
        switch value.storage {
        case .null: code = library.bindings.null(statement, index)
        case .int64(let n): code = library.bindings.int64(statement, index, n)
        case .double(let d): code = library.bindings.double(statement, index, d)
        case .string(let string):
          code = string.withCString {
            library.bindings.text(statement, index, $0, Int32(string.utf8.count))
          }
        case .blob(let data):
          code = data.withUnsafeBytes {
            library.bindings.blob(
              statement,
              index,
              $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1),
              Int32($0.count)
            )
          }
        }
        guard code == 0 else {
          finalize()
          throw error(code)
        }
      }
    }

    deinit {
      finalize()
    }

    private func error(_ code: Int32) -> SQLiteError {
      let extended = library.connections.extendedErrorCode(connection)
      let message = library.connections.errorMessage(connection).map { String(cString: $0) }
      return SQLiteError(
        code: SQLiteResultCode(rawValue: extended != 0 ? extended : code),
        message: message,
        sql: sql
      )
    }

    func finalize() {
      if let pointer { _ = library.statements.execution.finalize(pointer) }
      pointer = nil
    }

    /// The columns of the next row, or nil when done.
    func step() throws -> [(String, DatabaseValue)]? {
      try access.checkAccess()
      guard let statement = pointer else { return nil }
      if !published {
        published = true
        try access.notifyReads(in: readRegion)
      }
      let code = library.statements.execution.step(statement)
      switch code {
      case 100:
        let columns = library.columns
        let count = columns.count(statement)
        var values: [(String, DatabaseValue)] = []
        values.reserveCapacity(Int(count))
        var index: Int32 = 0
        while index < count {
          defer { index += 1 }
          let name = columnNames[Int(index)]
          switch columns.type(statement, index) {
          case 1:
            values.append((name, DatabaseValue(storage: .int64(columns.int64(statement, index)))))
          case 2:
            values.append((name, DatabaseValue(storage: .double(columns.double(statement, index)))))
          case 3:
            let length = Int(columns.byteCount(statement, index))
            let text = columns.text(statement, index)
              .map {
                String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
              }
            values.append((name, DatabaseValue(storage: .string(text ?? ""))))
          case 4:
            let length = Int(columns.byteCount(statement, index))
            let data = columns.blob(statement, index).map { Data(bytes: $0, count: length) }
            values.append((name, DatabaseValue(storage: .blob(data ?? Data()))))
          default: values.append((name, .null))
          }
        }
        return values
      case 101:
        finalize()
        return nil
      default:
        let error = error(code)
        finalize()
        throw error
      }
    }
  }

  public struct ColumnInfo: Sendable {
    public let cid: Int
    public let name: String
    public let type: String
    public let notNull: Bool
    public let defaultValueSQL: String?
    public let primaryKeyIndex: Int

    /// Whether the column has a NOT NULL constraint.
    public var isNotNull: Bool { notNull }
  }

  public struct PrimaryKeyInfo: Sendable {
    public let columns: [String]
    public let rowIDColumn: String?
    let hiddenRowID: Bool

    /// The primary key columns, or nil for the hidden rowid of a table without primary key.
    public var columnInfos: [ColumnInfo]?

    public var isRowID: Bool {
      rowIDColumn != nil || hiddenRowID
    }
  }

  public final class RowCursor: Cursor {
    enum Source {
      case native(SQLiteStatementCursor)
      case raw(RawSelectStatement)

      var columnNames: [String] {
        switch self {
        case .native(let cursor): cursor.columnNames
        case .raw(let statement): statement.columnNames
        }
      }

      func close() {
        switch self {
        case .native(let cursor): try? cursor.close()
        case .raw(let statement): statement.finalize()
        }
      }
    }

    private let source: Source
    private let baseRow: Row
    private let row: Row
    public let sql: String
    public let arguments: StatementArguments
    public let columnNames: [String]

    public var columnCount: Int {
      columnNames.count
    }

    public var databaseRegion: DatabaseRegion {
      switch source {
      case .native(let cursor): DatabaseRegion(cursor.readRegion)
      case .raw(let statement): DatabaseRegion(statement.region)
      }
    }

    init(
      _ source: Source,
      sql: String,
      arguments: StatementArguments,
      adapter: (any RowAdapter)?
    ) throws {
      let baseRow = Row()
      baseRow.storedIsFetched = true
      self.baseRow = baseRow
      columnNames = source.columnNames
      if let adapter {
        let layout = _LayoutedColumnMapping(layoutColumns: Array(columnNames.enumerated()))
        row = try Row(base: baseRow, adapter: adapter._layoutedAdapter(from: layout))
      } else {
        row = baseRow
      }
      self.source = source
      self.sql = sql
      self.arguments = arguments
    }

    deinit {
      source.close()
    }

    // Starts the statement trace on the first step, as SQLite does.
    var trace: (() -> StatementTrace?)?
    var boundValues: [DatabaseValue]?
    private var failure: DatabaseError?
    var publicStatementArguments = false
    private var activeTrace: StatementTrace?

    public func next() throws -> Row? {
      if let trace {
        self.trace = nil
        activeTrace = trace()
      }
      // As with SQLite, a statement that failed keeps failing.
      if let failure {
        throw failure
      }
      let columns: [(String, DatabaseValue)]?
      do {
        switch source {
        case .native(let cursor):
          columns = try cursor.next()?.map { ($0.0, DatabaseValue($0.1)) }
        case .raw(let statement):
          columns = try statement.step()
        }
      } catch let error as SQLiteError {
        let failure = DatabaseError(
          error,
          arguments: boundValues.map { StatementArguments($0) } ?? arguments,
          publicStatementArguments: publicStatementArguments
        )
        self.failure = failure
        throw failure
      }
      guard let columns else {
        activeTrace?.finish()
        activeTrace = nil
        return nil
      }
      baseRow.columns = columns
      return row
    }
  }

  extension Row {
    public static func fetchCursor(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> RowCursor {
      try db.cursor(sql: sql, arguments: arguments, adapter: adapter)
    }

    public static func fetchAll(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> [Row] {
      try Array(fetchCursor(db, sql: sql, arguments: arguments, adapter: adapter).map { $0.copy() })
    }

    public static func fetchOne(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> Row? {
      try fetchCursor(db, sql: sql, arguments: arguments, adapter: adapter).next()?.copy()
    }

    public static func fetchCursor(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    )
      throws -> RowCursor
    {
      try statement.makeCursor(arguments: arguments, adapter: adapter)
    }

    public static func fetchAll(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> [Row]
    {
      try Array(fetchCursor(statement, arguments: arguments, adapter: adapter).map { $0.copy() })
    }

    public static func fetchOne(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> Row?
    {
      try fetchCursor(statement, arguments: arguments, adapter: adapter).next()?.copy()
    }

    public static func fetchAll(_ db: Database, _ literal: SQL) throws -> [Row] {
      try fetchAll(db, sql: literal.sql, arguments: literal.arguments)
    }

    public static func fetchOne(_ db: Database, _ literal: SQL) throws -> Row? {
      try fetchOne(db, sql: literal.sql, arguments: literal.arguments)
    }
  }

  public final class Statement {
    let database: Database
    let cached: Bool
    public let sql: String

    public var arguments = StatementArguments() {
      didSet {
        unchecked = false
      }
    }

    var persistenceCursors: [RowCursor]?
    var unchecked = false
    public let columnNames: [String]

    public var columnCount: Int {
      columnNames.count
    }

    public let databaseRegion: DatabaseRegion

    /// Whether the statement does not write to the database.
    public let isReadonly: Bool

    // The row being dumped, read by dump formats.
    var dumpedRow: Row?

    init(database: Database, sql: String, cached: Bool) throws {
      self.database = database
      self.sql = trimmedSQLStatement(sql)
      self.cached = cached
      let info = try translate { try database.access.statementInfo(sql) }
      columnNames = info.columnNames
      databaseRegion = DatabaseRegion(info.readRegion)
      isReadonly = info.isReadOnly
    }

    /// The index of the leftmost column with the given name, compared case-insensitively.
    public func index(ofColumn name: String) -> Int? {
      columnNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func validateArguments(_ arguments: StatementArguments) throws {
      _ = try bindArguments(arguments, sql: sql)
    }

    public func setArguments(_ arguments: StatementArguments) throws {
      try validateArguments(arguments)
      self.arguments = arguments
    }

    public func setUncheckedArguments(_ arguments: StatementArguments) {
      self.arguments = arguments
      unchecked = true
    }

    func makeCursor(
      arguments: StatementArguments?,
      adapter: (any RowAdapter)? = nil
    ) throws -> RowCursor {
      let cursor = try database.cursor(
        sql: sql,
        arguments: arguments ?? self.arguments,
        cached: cached,
        unchecked: arguments == nil && unchecked,
        adapter: adapter
      )
      persistenceCursors?.append(cursor)
      return cursor
    }

    func finishPersistenceExecution() throws {
      for cursor in persistenceCursors ?? [] {
        while try cursor.next() != nil {}
      }
      persistenceCursors = nil
    }

    public func execute(arguments: StatementArguments? = nil) throws {
      let cursor = try makeCursor(arguments: arguments)
      while try cursor.next() != nil {}
      if !database.isInsideTransaction {
        database.deliverRegionChanges()
      }
    }
  }

#endif
