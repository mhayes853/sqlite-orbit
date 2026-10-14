#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public struct ColumnType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    public static let integer = Self(rawValue: "INTEGER")
    public static let text = Self(rawValue: "TEXT")
    public static let blob = Self(rawValue: "BLOB")
    public static let real = Self(rawValue: "REAL")
    public static let double = Self(rawValue: "DOUBLE")
    public static let numeric = Self(rawValue: "NUMERIC")
    public static let boolean = Self(rawValue: "BOOLEAN")
    public static let date = Self(rawValue: "DATE")
    public static let datetime = Self(rawValue: "DATETIME")
    public static let any = Self(rawValue: "ANY")
  }

  public struct TableOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let ifNotExists = Self(rawValue: 1)
    public static let temporary = Self(rawValue: 2)
    public static let withoutRowID = Self(rawValue: 4)
    public static let strict = Self(rawValue: 8)
  }

  extension Database {
    public typealias ColumnType = SQLiteOrbitGRDB.ColumnType

    public enum ForeignKeyAction: String {
      case cascade = "CASCADE"
      case restrict = "RESTRICT"
      case setNull = "SET NULL"
      case setDefault = "SET DEFAULT"
      case noAction = "NO ACTION"
    }

    public func create(
      table name: String,
      options: TableOptions = [],
      body: (TableDefinition) throws -> Void
    ) throws {
      let definition = TableDefinition()
      try body(definition)
      var sql =
        "CREATE " + (options.contains(.temporary) ? "TEMPORARY " : "") + "TABLE "
        + (options.contains(.ifNotExists) ? "IF NOT EXISTS " : "") + quoted(name) + " ("
      sql += (definition.columns.map(\.sql) + definition.constraints).joined(separator: ", ") + ")"
      let suffix = [
        options.contains(.withoutRowID) ? "WITHOUT ROWID" : nil,
        options.contains(.strict) ? "STRICT" : nil
      ]
      .compactMap { $0 }
      if !suffix.isEmpty {
        sql += " " + suffix.joined(separator: ", ")
      }
      try execute(sql: sql)
      for column in definition.columns where column.isIndexed {
        try create(index: name + "_on_" + column.name, on: name, columns: [column.name])
      }
    }

    public func alter(table name: String, body: (TableAlteration) throws -> Void) throws {
      let alteration = TableAlteration()
      try body(alteration)
      for column in alteration.added {
        try execute(sql: "ALTER TABLE \(quoted(name)) ADD COLUMN \(column.sql)")
      }
      for action in alteration.actions {
        try execute(sql: "ALTER TABLE \(quoted(name)) \(action)")
      }
    }

    public func drop(table name: String) throws {
      try execute(sql: "DROP TABLE \(quoted(name))")
    }

    public func rename(table name: String, to newName: String) throws {
      try execute(sql: "ALTER TABLE \(quoted(name)) RENAME TO \(quoted(newName))")
    }

    public func create(
      index name: String,
      on table: String,
      columns: [String],
      unique: Bool = false,
      ifNotExists: Bool = false
    ) throws {
      try execute(
        sql: "CREATE " + (unique ? "UNIQUE " : "") + "INDEX "
          + (ifNotExists ? "IF NOT EXISTS " : "")
          + quoted(name) + " ON " + quoted(table) + " ("
          + columns.map(quoted).joined(separator: ", ")
          + ")"
      )
    }

    public func drop(index name: String) throws {
      try execute(sql: "DROP INDEX \(quoted(name))")
    }
  }

  public final class ColumnDefinition {
    let name: String
    let type: ColumnType?
    var clauses: [String] = []
    var isIndexed = false

    init(name: String, type: ColumnType?) {
      self.name = name
      self.type = type
    }

    var sql: String {
      ([quoted(name)] + (type.map { [$0.rawValue] } ?? []) + clauses).joined(separator: " ")
    }

    @discardableResult
    public func notNull(onConflict conflict: Database.ConflictResolution? = nil)
      -> Self
    {
      clauses.append(
        "NOT NULL" + (conflict.map { " ON CONFLICT " + $0.rawValue.uppercased() } ?? "")
      )
      return self
    }

    @discardableResult
    public func primaryKey(
      onConflict conflict: Database.ConflictResolution? = nil,
      autoincrement: Bool = false
    ) -> Self {
      clauses.append(
        "PRIMARY KEY" + (conflict.map { " ON CONFLICT " + $0.rawValue.uppercased() } ?? "")
          + (autoincrement ? " AUTOINCREMENT" : "")
      )
      return self
    }

    @discardableResult
    public func unique(onConflict conflict: Database.ConflictResolution? = nil)
      -> Self
    {
      clauses.append("UNIQUE" + (conflict.map { " ON CONFLICT " + $0.rawValue.uppercased() } ?? ""))
      return self
    }

    @discardableResult
    public func defaults(to value: (any DatabaseValueConvertible)?) -> Self {
      clauses.append("DEFAULT " + (value?.databaseValue ?? .null).sqlLiteral)
      return self
    }

    @discardableResult
    public func indexed() -> Self {
      isIndexed = true
      return self
    }

    @discardableResult
    public func references(
      _ table: String,
      column: String? = nil,
      onDelete: Database.ForeignKeyAction? = nil,
      onUpdate: Database.ForeignKeyAction? = nil,
      deferred: Bool = false
    ) -> Self {
      clauses.append(
        referenceSQL(
          table: table,
          columns: column.map { [$0] },
          onDelete: onDelete,
          onUpdate: onUpdate,
          deferred: deferred
        )
      )
      return self
    }

    @discardableResult
    public func check(sql: String) -> Self {
      clauses.append("CHECK (\(sql))")
      return self
    }

    @discardableResult
    public func collate(_ collation: String) -> Self {
      clauses.append("COLLATE " + quoted(collation))
      return self
    }
  }

  public final class TableDefinition {
    var columns: [ColumnDefinition] = []
    var constraints: [String] = []

    @discardableResult
    public func column(_ name: String, _ type: ColumnType? = nil)
      -> ColumnDefinition
    {
      let column = ColumnDefinition(name: name, type: type)
      columns.append(column)
      return column
    }

    @discardableResult
    public func primaryKey(_ name: String, _ type: ColumnType = .integer)
      -> ColumnDefinition
    {
      column(name, type).primaryKey()
    }

    @discardableResult
    public func autoIncrementedPrimaryKey(
      _ name: String,
      onConflict conflict: Database.ConflictResolution? = nil
    ) -> ColumnDefinition {
      column(name, .integer).primaryKey(onConflict: conflict, autoincrement: true)
    }

    public func primaryKey(
      _ columns: [String],
      onConflict conflict: Database.ConflictResolution? = nil
    ) {
      constraints.append(
        "PRIMARY KEY (" + columns.map(quoted).joined(separator: ", ") + ")"
          + (conflict.map { " ON CONFLICT " + $0.rawValue.uppercased() } ?? "")
      )
    }

    public func uniqueKey(
      _ columns: [String],
      onConflict conflict: Database.ConflictResolution? = nil
    ) {
      constraints.append(
        "UNIQUE (" + columns.map(quoted).joined(separator: ", ") + ")"
          + (conflict.map { " ON CONFLICT " + $0.rawValue.uppercased() } ?? "")
      )
    }

    public func foreignKey(
      _ columns: [String],
      references table: String,
      columns destination: [String]? = nil,
      onDelete: Database.ForeignKeyAction? = nil,
      onUpdate: Database.ForeignKeyAction? = nil,
      deferred: Bool = false
    ) {
      constraints.append(
        "FOREIGN KEY (" + columns.map(quoted).joined(separator: ", ") + ") "
          + referenceSQL(
            table: table,
            columns: destination,
            onDelete: onDelete,
            onUpdate: onUpdate,
            deferred: deferred
          )
      )
    }

    public func check(sql: String) {
      constraints.append("CHECK (\(sql))")
    }
  }

  public final class TableAlteration {
    var added: [ColumnDefinition] = []
    var actions: [String] = []

    @discardableResult
    public func add(column name: String, _ type: ColumnType? = nil)
      -> ColumnDefinition
    {
      let column = ColumnDefinition(name: name, type: type)
      added.append(column)
      return column
    }

    public func rename(column name: String, to newName: String) {
      actions.append("RENAME COLUMN \(quoted(name)) TO \(quoted(newName))")
    }

    public func drop(column name: String) {
      actions.append("DROP COLUMN " + quoted(name))
    }
  }

  private func referenceSQL(
    table: String,
    columns: [String]?,
    onDelete: Database.ForeignKeyAction?,
    onUpdate: Database.ForeignKeyAction?,
    deferred: Bool
  ) -> String {
    "REFERENCES " + quoted(table)
      + (columns.map { " (" + $0.map(quoted).joined(separator: ", ") + ")" } ?? "")
      + (onDelete.map { " ON DELETE " + $0.rawValue } ?? "")
      + (onUpdate.map { " ON UPDATE " + $0.rawValue } ?? "")
      + (deferred ? " DEFERRABLE INITIALLY DEFERRED" : "")
  }

#endif
