#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  @_spi(GRDB) import SQLiteOrbit

  public final class Database {
    public enum TransactionCompletion { case commit, rollback }
    public enum TransactionKind { case deferred, immediate, exclusive }
    public enum ConflictResolution: String, Sendable { case rollback, abort, fail, ignore, replace }
    let access: SQLiteGRDBAccess
    init(_ access: SQLiteGRDBAccess) { self.access = access }
    public var sqliteConnection: OpaquePointer? {
      precondition((try? access.checkAccess()) != nil, "database access outlived its closure")
      return access.sqliteConnection
    }
    public var changesCount: Int { checked { Int(access.changesCount) } }
    public var totalChangesCount: Int { try! Int.fetchOne(self, sql: "SELECT total_changes()")! }
    public var lastInsertedRowID: Int64 { checked { access.lastInsertedRowID } }
    public var isInsideTransaction: Bool { checked { access.isInsideTransaction } }
    private func checked<T>(_ body: () -> T) -> T {
      do { try access.checkAccess() } catch { preconditionFailure(String(describing: error)) }
      return body()
    }
    public func execute(sql: String, arguments: StatementArguments = StatementArguments()) throws {
      try translate {
        var remaining = sql
        var arguments = arguments
        while true {
          let part = try access.firstStatement(remaining)
          guard let text = part.statement else { break }
          let bound = try bindArguments(arguments, sql: text, allowRemaining: true)
          let cursor = try access.cursor(
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
    public func inTransaction(
      _ kind: TransactionKind? = nil,
      _ body: () throws -> TransactionCompletion
    ) throws {
      guard kind == nil || kind == .immediate else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "Orbit supports immediate write transactions"
        )
      }
      try translate {
        try access.inTransaction { _ in try body() == .commit }
      }
    }
    public func inSavepoint(_ body: () throws -> TransactionCompletion) throws {
      if !isInsideTransaction { return try inTransaction(nil, body) }
      let name = "orbit_grdb_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      try execute(sql: "SAVEPOINT \(name)")
      do {
        if try body() == .rollback { try execute(sql: "ROLLBACK TO SAVEPOINT \(name)") }
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
          try access.cursor(
            SQLiteOrbit.SQL(text: sql, bindings: bound.values.map(\.orbitValue)),
            cached: cached
          ),
          sql: sql,
          arguments: arguments
        )
      }
    }
    public func tableExists(_ name: String) throws -> Bool {
      try Bool.fetchOne(
        self,
        sql:
          "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ? COLLATE NOCASE)",
        arguments: [name]
      ) ?? false
    }
    public func viewExists(_ name: String) throws -> Bool {
      try Bool.fetchOne(
        self,
        sql:
          "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'view' AND name = ? COLLATE NOCASE)",
        arguments: [name]
      ) ?? false
    }
    public func columns(in table: String) throws -> [ColumnInfo] {
      guard try tableExists(table) || viewExists(table) else {
        throw DatabaseError(message: "no such table: \(table)")
      }
      return try Row.fetchAll(self, sql: "SELECT * FROM pragma_table_info(?)", arguments: [table])
        .map {
          ColumnInfo(
            cid: $0["cid"],
            name: $0["name"],
            type: $0["type"],
            notNull: $0["notnull"],
            defaultValueSQL: $0["dflt_value"],
            primaryKeyIndex: $0["pk"]
          )
        }
    }
    public func primaryKey(_ table: String) throws -> PrimaryKeyInfo {
      let tableColumns = try columns(in: table)
      let columns = tableColumns.filter { $0.primaryKeyIndex > 0 }
        .sorted { $0.primaryKeyIndex < $1.primaryKeyIndex }
      guard try tableExists(table) else { throw DatabaseError(message: "no such table: \(table)") }
      // INTEGER PRIMARY KEY is a rowid alias only when SQLite has not built a primary-key index
      // (WITHOUT ROWID and the inline DESC exception both have such an index).
      let hasPrimaryKeyIndex =
        try Bool.fetchOne(
          self,
          sql: "SELECT EXISTS(SELECT 1 FROM pragma_index_list(?) WHERE origin = 'pk')",
          arguments: [table]
        ) ?? false
      let integer =
        columns.count == 1 && columns[0].type.uppercased() == "INTEGER" && !hasPrimaryKeyIndex
        ? columns[0].name : nil
      let keyColumns: [String]
      if columns.isEmpty {
        let names = Set(tableColumns.map { $0.name.lowercased() })
        guard let alias = ["rowid", "_rowid_", "oid"].first(where: { !names.contains($0) }) else {
          throw DatabaseError(message: "table has no accessible primary key: \(table)")
        }
        keyColumns = [alias]
      } else {
        keyColumns = columns.map(\.name)
      }
      return PrimaryKeyInfo(columns: keyColumns, rowIDColumn: integer, hiddenRowID: columns.isEmpty)
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
    public var isRowID: Bool { rowIDColumn != nil || hiddenRowID }
  }

  public final class RowCursor: Cursor {
    private let cursor: SQLiteGRDBCursor
    private let row = Row()
    public let sql: String
    public let arguments: StatementArguments
    public var columnNames: [String] { cursor.columnNames }
    public var columnCount: Int { columnNames.count }
    public var databaseRegion: DatabaseRegion { DatabaseRegion(cursor.databaseRegion) }
    init(_ cursor: SQLiteGRDBCursor, sql: String, arguments: StatementArguments) {
      self.cursor = cursor
      self.sql = sql
      self.arguments = arguments
    }
    deinit { cursor.release() }
    public func next() throws -> Row? {
      try translate {
        guard let columns = try cursor.next() else { return nil }
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
      try statement.database.cursor(
        sql: statement.sql,
        arguments: arguments ?? statement.arguments,
        cached: statement.cached,
        unchecked: arguments == nil && statement.unchecked
      )
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
    public var arguments = StatementArguments() { didSet { unchecked = false } }
    var unchecked = false
    public let columnNames: [String]
    public var columnCount: Int { columnNames.count }
    public let databaseRegion: DatabaseRegion
    init(database: Database, sql: String, cached: Bool) throws {
      self.database = database
      self.sql = sql
      self.cached = cached
      let info = try translate { try database.access.inspectStatement(sql) }
      columnNames = info.columns
      databaseRegion = DatabaseRegion(info.region)
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
    public func execute(arguments: StatementArguments? = nil) throws {
      let cursor = try database.cursor(
        sql: sql,
        arguments: arguments ?? self.arguments,
        cached: cached,
        unchecked: arguments == nil && unchecked
      )
      while try cursor.next() != nil {}
    }
  }

#endif
