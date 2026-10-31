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
      try! Int.fetchOne(self, sql: "SELECT total_changes()")!
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
      try execute(sql: literal.sql, arguments: literal.arguments)
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
      let statement = try makeStatement(sql: literal.sql)
      statement.arguments = literal.arguments
      return statement
    }

    public func cachedStatement(sql: String) throws -> Statement {
      try Statement(database: self, sql: singleStatement(sql), cached: true)
    }

    public func cachedStatement(literal: SQL) throws -> Statement {
      let statement = try cachedStatement(sql: literal.sql)
      statement.arguments = literal.arguments
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
      defer { connectionState.transactionDidEnd(self, committed: committed) }
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
        let cursor = try access.statementCursor(
          SQLiteOrbit.SQL(text: sql, bindings: bound.values.map(\.orbitValue)),
          cached: cached
        )
        do {
          let rows = try RowCursor(cursor, sql: sql, arguments: arguments, adapter: adapter)
          rows.trace = { [weak self] in self?.traceStatement(sql: sql, values: bound.values) }
          rows.boundValues = bound.values
          rows.publicStatementArguments = connectionState.publicStatementArguments
          return rows
        } catch {
          try? cursor.close()
          throw error
        }
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
    private let cursor: SQLiteStatementCursor
    private let baseRow: Row
    private let row: Row
    public let sql: String
    public let arguments: StatementArguments

    public var columnNames: [String] {
      cursor.columnNames
    }

    public var columnCount: Int {
      columnNames.count
    }

    public var databaseRegion: DatabaseRegion {
      DatabaseRegion(cursor.readRegion)
    }

    init(
      _ cursor: SQLiteStatementCursor,
      sql: String,
      arguments: StatementArguments,
      adapter: (any RowAdapter)?
    ) throws {
      let baseRow = Row()
      baseRow.storedIsFetched = true
      self.baseRow = baseRow
      if let adapter {
        let layout = _LayoutedColumnMapping(layoutColumns: Array(cursor.columnNames.enumerated()))
        row = try Row(base: baseRow, adapter: adapter._layoutedAdapter(from: layout))
      } else {
        row = baseRow
      }
      self.cursor = cursor
      self.sql = sql
      self.arguments = arguments
    }

    deinit {
      try? cursor.close()
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
      let columns: SQLiteStatementCursor.Element?
      do {
        columns = try cursor.next()
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
      baseRow.columns = columns.map { ($0.0, DatabaseValue($0.1)) }
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

    init(database: Database, sql: String, cached: Bool) throws {
      self.database = database
      self.sql = trimmedSQLStatement(sql)
      self.cached = cached
      let info = try translate { try database.access.statementInfo(sql) }
      columnNames = info.columnNames
      databaseRegion = DatabaseRegion(info.readRegion)
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
