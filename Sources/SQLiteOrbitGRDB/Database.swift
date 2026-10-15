#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  private struct DatabaseRollback: Error {}

  public final class Database {
    public enum TransactionCompletion {
      case commit, rollback
    }

    public enum TransactionKind {
      case deferred, immediate, exclusive
    }

    public enum ConflictResolution: String, Sendable {
      case rollback, abort, fail, ignore, replace
    }

    let access: SQLiteScopedAccess

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
          while try cursor.next() != nil {}
          arguments.consume(bound.consumed)
          remaining = part.remainder
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
      try Statement(database: self, sql: sql, cached: false)
    }

    public func makeStatement(literal: SQL) throws -> Statement {
      let statement = try makeStatement(sql: literal.sql)
      statement.arguments = literal.arguments
      return statement
    }

    public func cachedStatement(sql: String) throws -> Statement {
      try Statement(database: self, sql: sql, cached: true)
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
      let mode: SQLiteWriteTransactionMode =
        switch kind ?? .immediate {
        case .deferred: .deferred
        case .immediate: .immediate
        case .exclusive: .exclusive
        }
      try translate {
        do {
          try access.transaction(mode: mode) { _ in
            if try body() == .rollback {
              throw DatabaseRollback()
            }
          }
        } catch is DatabaseRollback {}
      }
    }

    public func inSavepoint(_ body: () throws -> TransactionCompletion) throws {
      if !isInsideTransaction {
        return try inTransaction(nil, body)
      }
      let name = "orbit_grdb_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      try execute(sql: "SAVEPOINT \(name)")
      do {
        if try body() == .rollback {
          try execute(sql: "ROLLBACK TO SAVEPOINT \(name)")
        }
        try execute(sql: "RELEASE SAVEPOINT \(name)")
      } catch {
        try? execute(sql: "ROLLBACK TO SAVEPOINT \(name)")
        try? execute(sql: "RELEASE SAVEPOINT \(name)")
        throw error
      }
    }

    func cursor(
      sql: String,
      arguments: StatementArguments,
      cached: Bool = false,
      unchecked: Bool = false
    ) throws -> RowCursor {
      try translate {
        let bound = try bindArguments(
          arguments,
          sql: sql,
          allowRemaining: unchecked,
          allowMissing: unchecked
        )
        return RowCursor(
          try access.statementCursor(
            SQLiteOrbit.SQL(text: sql, bindings: bound.values.map(\.orbitValue)),
            cached: cached
          ),
          sql: sql,
          arguments: arguments
        )
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
  }

  public struct PrimaryKeyInfo: Sendable {
    public let columns: [String]
    public let rowIDColumn: String?
    let hiddenRowID: Bool

    public var isRowID: Bool {
      rowIDColumn != nil || hiddenRowID
    }
  }

  public final class RowCursor: Cursor {
    private let cursor: SQLiteStatementCursor
    private let row = Row()
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

    init(_ cursor: SQLiteStatementCursor, sql: String, arguments: StatementArguments) {
      self.cursor = cursor
      self.sql = sql
      self.arguments = arguments
    }

    deinit {
      try? cursor.close()
    }

    public func next() throws -> Row? {
      try translate {
        guard let columns = try cursor.next() else {
          return nil
        }
        row.columns = columns.map { ($0.0, DatabaseValue($0.1)) }
        return row
      }
    }
  }

  extension Row {
    public static func fetchCursor(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> RowCursor {
      try db.cursor(sql: sql, arguments: arguments)
    }

    public static func fetchAll(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> [Row] {
      try Array(fetchCursor(db, sql: sql, arguments: arguments).map { $0.copy() })
    }

    public static func fetchOne(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> Row? {
      try fetchCursor(db, sql: sql, arguments: arguments).next()?.copy()
    }

    public static func fetchCursor(_ statement: Statement, arguments: StatementArguments? = nil)
      throws -> RowCursor
    {
      try statement.makeCursor(arguments: arguments)
    }

    public static func fetchAll(_ statement: Statement, arguments: StatementArguments? = nil) throws
      -> [Row]
    {
      try Array(fetchCursor(statement, arguments: arguments).map { $0.copy() })
    }

    public static func fetchOne(_ statement: Statement, arguments: StatementArguments? = nil) throws
      -> Row?
    {
      try fetchCursor(statement, arguments: arguments).next()?.copy()
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
      self.sql = sql
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

    func makeCursor(arguments: StatementArguments?) throws -> RowCursor {
      let cursor = try database.cursor(
        sql: sql,
        arguments: arguments ?? self.arguments,
        cached: cached,
        unchecked: arguments == nil && unchecked
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
    }
  }

#endif
