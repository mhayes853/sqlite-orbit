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
    public static let jsonText = Self(rawValue: "TEXT")
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

    public enum ForeignKeyAction: String, Sendable {
      case cascade = "CASCADE"
      case restrict = "RESTRICT"
      case setNull = "SET NULL"
      case setDefault = "SET DEFAULT"
      case noAction = "NO ACTION"
    }

    /// Creates a table.
    public func create(
      table name: String,
      options: TableOptions = [],
      body: (TableDefinition) throws -> Void
    ) throws {
      let definition = TableDefinition(name: name, options: options)
      try body(definition)
      try execute(sql: definition.sql(self))
    }

    /// Modifies a table.
    public func alter(table name: String, body: (TableAlteration) throws -> Void) throws {
      let alteration = TableAlteration(name: name)
      try body(alteration)
      try execute(sql: alteration.sql(self))
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
      ifNotExists: Bool = false,
      condition: (any SQLExpressible)? = nil
    ) throws {
      var options: IndexOptions = []
      if unique {
        options.insert(.unique)
      }
      if ifNotExists {
        options.insert(.ifNotExists)
      }
      try create(index: name, on: table, columns: columns, options: options, condition: condition)
    }

    public func drop(index name: String) throws {
      try execute(sql: "DROP INDEX \(quoted(name))")
    }

    static func defaultIndexName(on table: String, columns: [String]) -> String {
      "index_\(table)_on_\(columns.joined(separator: "_"))"
    }
  }

  /// `CREATE INDEX name ON table(expressions) WHERE condition`, with literal values.
  func indexSQL(
    _ db: Database,
    name: String,
    table: String,
    expressions: [SQLExpression],
    options: IndexOptions,
    condition: SQLExpression? = nil
  ) throws -> String {
    var sql = "CREATE" + (options.contains(.unique) ? " UNIQUE" : "") + " INDEX"
    if options.contains(.ifNotExists) { sql += " IF NOT EXISTS" }
    let context = SQLGenerationContext(db, literalValues: true)
    sql +=
      try " \(quoted(name)) ON \(quoted(table))("
      + expressions.map { try $0.sql(context) }.joined(separator: ", ") + ")"
    if let condition {
      sql += try " WHERE " + condition.sql(context)
    }
    return sql
  }

  // MARK: - ColumnDefinition

  /// The definition of a table column.
  public final class ColumnDefinition {
    enum Indexing {
      case index
      case unique(Database.ConflictResolution)
    }

    struct Reference {
      var table: String
      var column: String?
      var onDelete: Database.ForeignKeyAction?
      var onUpdate: Database.ForeignKeyAction?
      var deferred: Bool
    }

    let name: String
    let type: ColumnType?
    var primaryKey: (conflict: Database.ConflictResolution?, autoincrement: Bool)?
    var notNullConflict: Database.ConflictResolution?
    var indexing: Indexing?
    var checkClauses: [SQL] = []
    var defaultClause: SQL?
    var collationName: String?
    var references: [Reference] = []
    var generatedClause: SQL?
    var literalClauses: [SQL] = []

    var isIndexed: Bool {
      if case .index = indexing { return true }
      return false
    }

    init(name: String, type: ColumnType?) {
      self.name = name
      self.type = type
    }

    @discardableResult
    public func notNull(onConflict conflict: Database.ConflictResolution? = nil) -> Self {
      notNullConflict = conflict ?? .abort
      return self
    }

    @discardableResult
    public func primaryKey(
      onConflict conflict: Database.ConflictResolution? = nil,
      autoincrement: Bool = false
    ) -> Self {
      primaryKey = (conflict, autoincrement)
      return self
    }

    @discardableResult
    public func unique(onConflict conflict: Database.ConflictResolution? = nil) -> Self {
      indexing = .unique(conflict ?? .abort)
      return self
    }

    @discardableResult
    public func indexed() -> Self {
      if indexing == nil { indexing = .index }
      return self
    }

    @discardableResult
    public func defaults(to value: (any DatabaseValueConvertible)?) -> Self {
      defaultClause =
        SQL(sql: "DEFAULT ") + SQL(elements: [.expression(SQLExpression(value: value))])
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
      references.append(
        Reference(
          table: table,
          column: column,
          onDelete: onDelete,
          onUpdate: onUpdate,
          deferred: deferred
        )
      )
      return self
    }

    @discardableResult
    public func check(sql: String) -> Self {
      checkClauses.append(SQL(sql: "CHECK (\(sql))"))
      return self
    }

    @discardableResult
    public func collate(_ collation: String) -> Self {
      collationName = collation
      return self
    }

    /// The SQL of the column definition. `primaryKey` provides the table's own primary key
    /// columns, for self-referencing foreign keys.
    func sql(
      _ db: Database,
      table: String,
      primaryKeyColumns: () throws -> [String]?
    ) throws -> String {
      let context = SQLGenerationContext(db, literalValues: true)
      var chunks = [quoted(name)]
      if let type { chunks.append(type.rawValue) }
      if let primaryKey {
        chunks.append("PRIMARY KEY")
        if let conflict = primaryKey.conflict {
          chunks.append("ON CONFLICT " + conflict.sqlName)
        }
        if primaryKey.autoincrement { chunks.append("AUTOINCREMENT") }
      }
      switch notNullConflict {
      case nil: break
      case .abort?: chunks.append("NOT NULL")
      case let conflict?: chunks.append("NOT NULL ON CONFLICT " + conflict.sqlName)
      }
      if case .unique(let conflict) = indexing {
        chunks.append(conflict == .abort ? "UNIQUE" : "UNIQUE ON CONFLICT " + conflict.sqlName)
      }
      for clause in checkClauses {
        chunks.append(try clause.sql(context))
      }
      if let defaultClause {
        chunks.append(try defaultClause.sql(context))
      }
      if let collationName {
        chunks.append("COLLATE " + collationName)
      }
      for reference in references {
        let columns: [String]
        if let column = reference.column {
          columns = [column]
        } else if reference.table.lowercased() == table.lowercased() {
          columns = try primaryKeyColumns() ?? [Column.rowID.name]
        } else {
          columns = try db.primaryKey(reference.table).columns
        }
        chunks.append(
          referenceSQL(
            table: reference.table,
            columns: columns,
            onDelete: reference.onDelete,
            onUpdate: reference.onUpdate,
            deferred: reference.deferred
          )
        )
      }
      if let generatedClause {
        chunks.append(try generatedClause.sql(context))
      }
      for clause in literalClauses {
        chunks.append(try clause.sql(context))
      }
      return chunks.joined(separator: " ")
    }
  }

  // MARK: - ForeignKeyDefinition

  /// A foreign key defined with `TableDefinition.belongsTo(_:)`.
  public final class ForeignKeyDefinition {
    enum Indexing {
      case index, unique
    }

    var name: String
    var table: String?
    var onDelete: Database.ForeignKeyAction?
    var onUpdate: Database.ForeignKeyAction?
    var indexing: Indexing?
    var deferred: Bool
    var notNullConflict: Database.ConflictResolution?

    init(
      name: String,
      table: String?,
      onDelete: Database.ForeignKeyAction?,
      onUpdate: Database.ForeignKeyAction?,
      indexed: Bool,
      deferred: Bool
    ) {
      self.name = name
      self.table = table
      self.onDelete = onDelete
      self.onUpdate = onUpdate
      indexing = indexed ? .index : nil
      self.deferred = deferred
    }

    @discardableResult
    public func notNull(onConflict conflict: Database.ConflictResolution? = nil) -> Self {
      notNullConflict = conflict ?? .abort
      return self
    }

    @discardableResult
    public func unique() -> Self {
      indexing = .unique
      return self
    }

    /// The destination table and its primary key (nil for a hidden rowid).
    func destination(_ db: Database) throws -> (table: String, key: [(String, ColumnType?)]?) {
      let candidates = table.map { [$0] } ?? [name, name.pluralized]
      for candidate in candidates where try db.tableExists(candidate) {
        return (candidate, try primaryKeyColumns(db, table: candidate))
      }
      throw DatabaseError(message: "no such table: \(table ?? name)")
    }
  }

  /// The primary key columns of a table and their types, or nil for a hidden rowid.
  func primaryKeyColumns(_ db: Database, table: String) throws -> [(String, ColumnType?)]? {
    let key = try db.primaryKey(table)
    if key.rowIDColumn == nil && key.isRowID && key.columns.count == 1
      && ["rowid", "_rowid_", "oid"].contains(key.columns[0].lowercased())
    {
      return nil
    }
    let columns = try db.columns(in: table)
    return key.columns.map { name in
      let type = columns.first { $0.name.lowercased() == name.lowercased() }?.type
      return (name, type.flatMap { $0.isEmpty ? nil : ColumnType(rawValue: $0) })
    }
  }

  // MARK: - TableDefinition

  /// The definition of a table, in `Database.create(table:)`.
  public final class TableDefinition {
    struct KeyConstraint {
      enum Component {
        case column(String)
        case definition(ColumnDefinition)
        case foreignKey(ForeignKeyDefinition)
      }

      var components: [Component]
      var conflict: Database.ConflictResolution?
    }

    struct ForeignKeyConstraint {
      var columns: [String]
      var table: String
      var destinationColumns: [String]?
      var onDelete: Database.ForeignKeyAction?
      var onUpdate: Database.ForeignKeyAction?
      var deferred: Bool
    }

    enum ColumnComponent {
      case definition(ColumnDefinition)
      case literal(SQL)
      case foreignKey(ForeignKeyDefinition)
      case foreignKeyConstraint(ForeignKeyConstraint)
    }

    let name: String
    let options: TableOptions
    var columnComponents: [ColumnComponent] = []
    var inPrimaryKeyBody = false
    var primaryKeyConstraint: KeyConstraint?
    var uniqueKeyConstraints: [KeyConstraint] = []
    var checkConstraints: [SQL] = []
    var literalConstraints: [SQL] = []

    init(name: String, options: TableOptions) {
      self.name = name
      self.options = options
    }

    var columns: [ColumnDefinition] {
      columnComponents.compactMap {
        if case .definition(let column) = $0 { return column }
        return nil
      }
    }

    @discardableResult
    public func column(_ name: String, _ type: ColumnType? = nil) -> ColumnDefinition {
      let column = ColumnDefinition(name: name, type: type)
      columnComponents.append(.definition(column))
      if inPrimaryKeyBody {
        column.notNull()
        primaryKeyConstraint!.components.append(.definition(column))
      }
      return column
    }

    /// Appends a column defined with raw SQL.
    public func column(sql: String) {
      column(literal: SQL(sql: sql))
    }

    /// Appends a column defined with an SQL literal.
    public func column(literal: SQL) {
      columnComponents.append(.literal(literal))
    }

    @discardableResult
    public func primaryKey(
      _ name: String,
      _ type: ColumnType,
      onConflict conflict: Database.ConflictResolution? = nil
    ) -> ColumnDefinition {
      let column = column(name, type).primaryKey(onConflict: conflict)
      return type == .integer ? column : column.notNull()
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
      precondition(primaryKeyConstraint == nil, "can't define several primary keys")
      primaryKeyConstraint = KeyConstraint(
        components: columns.map { .column($0) },
        conflict: conflict
      )
    }

    /// Defines a primary key made of the columns defined in `body`.
    public func primaryKey(
      onConflict conflict: Database.ConflictResolution? = nil,
      body: () throws -> Void
    ) rethrows {
      precondition(primaryKeyConstraint == nil, "can't define several primary keys")
      primaryKeyConstraint = KeyConstraint(components: [], conflict: conflict)
      let old = inPrimaryKeyBody
      inPrimaryKeyBody = true
      defer { inPrimaryKeyBody = old }
      try body()
    }

    public func uniqueKey(
      _ columns: [String],
      onConflict conflict: Database.ConflictResolution? = nil
    ) {
      uniqueKeyConstraints.append(
        KeyConstraint(components: columns.map { .column($0) }, conflict: conflict)
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
      columnComponents.append(
        .foreignKeyConstraint(
          ForeignKeyConstraint(
            columns: columns,
            table: table,
            destinationColumns: destination,
            onDelete: onDelete,
            onUpdate: onUpdate,
            deferred: deferred
          )
        )
      )
    }

    /// Defines a foreign key to another table, named after it: `belongsTo("team")` creates
    /// a `teamId` column that references the `team` (or `teams`) table.
    @discardableResult
    public func belongsTo(
      _ name: String,
      inTable table: String? = nil,
      onDelete: Database.ForeignKeyAction? = nil,
      onUpdate: Database.ForeignKeyAction? = nil,
      deferred: Bool = false,
      indexed: Bool = true
    ) -> ForeignKeyDefinition {
      let foreignKey = ForeignKeyDefinition(
        name: name,
        table: table,
        onDelete: onDelete,
        onUpdate: onUpdate,
        indexed: indexed && !inPrimaryKeyBody,
        deferred: deferred
      )
      columnComponents.append(.foreignKey(foreignKey))
      if inPrimaryKeyBody {
        foreignKey.notNull()
        primaryKeyConstraint!.components.append(.foreignKey(foreignKey))
      }
      return foreignKey
    }

    public func check(sql: String) {
      checkConstraints.append(SQL(sql: "CHECK (\(sql))"))
    }

    // MARK: SQL generation

    private struct ExpandedForeignKey {
      var columnNames: [String]
      var columns: [ColumnDefinition]
      var constraint: ForeignKeyConstraint?
      var index: (name: String, columns: [String], unique: Bool)?
    }

    /// The primary key being defined, for self-references (nil when unknown or a rowid).
    private func forwardPrimaryKey(_ db: Database) throws -> [(String, ColumnType?)]? {
      if let constraint = primaryKeyConstraint {
        var result: [(String, ColumnType?)] = []
        for component in constraint.components {
          switch component {
          case .column(let name): result.append((name, nil))
          case .definition(let column): result.append((column.name, column.type))
          case .foreignKey(let foreignKey):
            let expanded = try expand(db, foreignKey, forward: nil)
            result += expanded.columns.map { ($0.name, $0.type) }
          }
        }
        return result
      }
      for column in columns where column.primaryKey != nil {
        return [(column.name, column.type)]
      }
      return nil
    }

    private func expand(
      _ db: Database,
      _ foreignKey: ForeignKeyDefinition,
      forward: [(String, ColumnType?)]??
    ) throws -> ExpandedForeignKey {
      let destinationTable: String
      let destinationKey: [(String, ColumnType?)]?
      let isSelfReference: Bool
      if let table = foreignKey.table {
        isSelfReference = table.lowercased() == name.lowercased()
      } else {
        isSelfReference =
          name.singularized.lowercased() == foreignKey.name.singularized.lowercased()
      }
      if isSelfReference, let forward {
        destinationTable = foreignKey.table ?? name
        destinationKey = forward
      } else {
        (destinationTable, destinationKey) = try foreignKey.destination(db)
      }
      func configure(_ column: ColumnDefinition) {
        if let conflict = foreignKey.notNullConflict { column.notNull(onConflict: conflict) }
      }
      guard let destinationKey else {
        let column = ColumnDefinition(name: foreignKey.name + "Id", type: .integer)
          .references(
            destinationTable,
            onDelete: foreignKey.onDelete,
            onUpdate: foreignKey.onUpdate,
            deferred: foreignKey.deferred
          )
        configure(column)
        switch foreignKey.indexing {
        case .index?: column.indexed()
        case .unique?: column.unique()
        case nil: break
        }
        return ExpandedForeignKey(columnNames: [column.name], columns: [column])
      }
      let names = destinationKey.map { foreignKey.name + $0.0.uppercasingFirstCharacter }
      if destinationKey.count == 1 {
        let column = ColumnDefinition(name: names[0], type: destinationKey[0].1)
          .references(
            destinationTable,
            column: destinationKey[0].0,
            onDelete: foreignKey.onDelete,
            onUpdate: foreignKey.onUpdate,
            deferred: foreignKey.deferred
          )
        configure(column)
        switch foreignKey.indexing {
        case .index?: column.indexed()
        case .unique?: column.unique()
        case nil: break
        }
        return ExpandedForeignKey(columnNames: names, columns: [column])
      }
      let columns = zip(destinationKey, names)
        .map { key, name -> ColumnDefinition in
          let column = ColumnDefinition(name: name, type: key.1)
          configure(column)
          return column
        }
      let constraint = ForeignKeyConstraint(
        columns: names,
        table: destinationTable,
        destinationColumns: nil,
        onDelete: foreignKey.onDelete,
        onUpdate: foreignKey.onUpdate,
        deferred: foreignKey.deferred
      )
      let index = foreignKey.indexing.map {
        (Database.defaultIndexName(on: name, columns: names), names, $0 == .unique)
      }
      return ExpandedForeignKey(
        columnNames: names,
        columns: columns,
        constraint: constraint,
        index: index
      )
    }

    func sql(_ db: Database) throws -> String {
      let forward = try forwardPrimaryKey(db)
      let indexOptions: IndexOptions = options.contains(.ifNotExists) ? [.ifNotExists] : []
      var items: [String] = []
      var foreignKeyConstraints: [ForeignKeyConstraint] = []
      var indexStatements: [String] = []
      var expandedColumns: [ColumnDefinition] = []
      let forwardNames = { forward?.map(\.0) }
      for component in columnComponents {
        switch component {
        case .definition(let column):
          items.append(try column.sql(db, table: name, primaryKeyColumns: forwardNames))
          expandedColumns.append(column)
        case .literal(let literal):
          items.append(try literal.sql(SQLGenerationContext(db, literalValues: true)))
        case .foreignKey(let foreignKey):
          let expanded = try expand(db, foreignKey, forward: .some(forward))
          for column in expanded.columns {
            items.append(try column.sql(db, table: name, primaryKeyColumns: forwardNames))
            expandedColumns.append(column)
          }
          if let constraint = expanded.constraint { foreignKeyConstraints.append(constraint) }
          if let index = expanded.index {
            indexStatements.append(
              try indexSQL(
                db,
                name: index.name,
                table: name,
                expressions: index.columns.map { .column($0) },
                options: index.unique ? indexOptions.union(.unique) : indexOptions
              )
            )
          }
        case .foreignKeyConstraint(let constraint):
          foreignKeyConstraints.append(constraint)
        }
      }
      func keyColumns(_ constraint: KeyConstraint) throws -> [String] {
        try constraint.components.flatMap { component -> [String] in
          switch component {
          case .column(let name): return [name]
          case .definition(let column): return [column.name]
          case .foreignKey(let foreignKey):
            return try expand(db, foreignKey, forward: .some(forward)).columnNames
          }
        }
      }
      if let constraint = primaryKeyConstraint {
        items.append(
          "PRIMARY KEY (" + (try keyColumns(constraint)).map(quoted).joined(separator: ", ") + ")"
            + (constraint.conflict.map { " ON CONFLICT " + $0.sqlName } ?? "")
        )
      }
      for constraint in uniqueKeyConstraints {
        items.append(
          "UNIQUE (" + (try keyColumns(constraint)).map(quoted).joined(separator: ", ") + ")"
            + (constraint.conflict.map { " ON CONFLICT " + $0.sqlName } ?? "")
        )
      }
      for constraint in foreignKeyConstraints {
        let destination: [String]
        if let columns = constraint.destinationColumns {
          destination = columns
        } else if constraint.table.lowercased() == name.lowercased() {
          destination = forward?.map(\.0) ?? [Column.rowID.name]
        } else {
          destination = try db.primaryKey(constraint.table).columns
        }
        items.append(
          "FOREIGN KEY (" + constraint.columns.map(quoted).joined(separator: ", ") + ") "
            + referenceSQL(
              table: constraint.table,
              columns: destination,
              onDelete: constraint.onDelete,
              onUpdate: constraint.onUpdate,
              deferred: constraint.deferred
            )
        )
      }
      let literalContext = SQLGenerationContext(db, literalValues: true)
      for constraint in checkConstraints + literalConstraints {
        items.append(try constraint.sql(literalContext))
      }
      var sql = "CREATE"
      if options.contains(.temporary) { sql += " TEMPORARY" }
      sql += " TABLE"
      if options.contains(.ifNotExists) { sql += " IF NOT EXISTS" }
      sql += " " + quoted(name) + " (" + items.joined(separator: ", ") + ")"
      var tableOptions: [String] = []
      if options.contains(.strict) { tableOptions.append("STRICT") }
      if options.contains(.withoutRowID) { tableOptions.append("WITHOUT ROWID") }
      if !tableOptions.isEmpty { sql += " " + tableOptions.joined(separator: ", ") }
      var statements = [sql]
      statements += indexStatements
      for column in expandedColumns where column.isIndexed {
        statements.append(
          try indexSQL(
            db,
            name: "\(name)_on_\(column.name)",
            table: name,
            expressions: [.column(column.name)],
            options: indexOptions
          )
        )
      }
      return statements.joined(separator: "; ")
    }
  }

  extension TableDefinition {
    /// Adds a CHECK constraint.
    public func check(_ condition: some SQLSpecificExpressible) {
      checkConstraints.append(
        SQL(sql: "CHECK (") + SQL(elements: [.expression(condition.sqlExpression)])
          + SQL(sql: ")")
      )
    }
  }

  // MARK: - TableAlteration

  /// The modifications of a table, in `Database.alter(table:)`.
  public final class TableAlteration {
    enum Alteration {
      case add(ColumnDefinition)
      case addLiteral(SQL)
      case rename(old: String, new: String)
      case drop(String)
    }

    let name: String
    var alterations: [Alteration] = []

    init(name: String) {
      self.name = name
    }

    @discardableResult
    public func add(column name: String, _ type: ColumnType? = nil) -> ColumnDefinition {
      let column = ColumnDefinition(name: name, type: type)
      alterations.append(.add(column))
      return column
    }

    /// Adds a column defined with raw SQL.
    public func addColumn(sql: String) {
      alterations.append(.addLiteral(SQL(sql: sql)))
    }

    /// Adds a column defined with an SQL literal.
    public func addColumn(literal: SQL) {
      alterations.append(.addLiteral(literal))
    }

    public func rename(column name: String, to newName: String) {
      alterations.append(.rename(old: name, new: newName))
    }

    public func drop(column name: String) {
      alterations.append(.drop(name))
    }

    func sql(_ db: Database) throws -> String {
      let prefix = "ALTER TABLE " + quoted(name)
      var statements: [String] = []
      for alteration in alterations {
        switch alteration {
        case .add(let column):
          let table = name
          statements.append(
            try prefix + " ADD COLUMN "
              + column.sql(
                db,
                table: name,
                primaryKeyColumns: {
                  try primaryKeyColumns(db, table: table)?.map(\.0)
                }
              )
          )
          if column.isIndexed {
            statements.append(
              try indexSQL(
                db,
                name: "\(name)_on_\(column.name)",
                table: name,
                expressions: [.column(column.name)],
                options: []
              )
            )
          }
        case .addLiteral(let literal):
          statements.append(
            try prefix + " ADD COLUMN " + literal.sql(SQLGenerationContext(db, literalValues: true))
          )
        case .rename(let old, let new):
          statements.append(prefix + " RENAME COLUMN \(quoted(old)) TO \(quoted(new))")
        case .drop(let column):
          statements.append(prefix + " DROP COLUMN " + quoted(column))
        }
      }
      return statements.joined(separator: "; ")
    }
  }

  private func referenceSQL(
    table: String,
    columns: [String],
    onDelete: Database.ForeignKeyAction?,
    onUpdate: Database.ForeignKeyAction?,
    deferred: Bool
  ) -> String {
    "REFERENCES " + quoted(table) + "(" + columns.map(quoted).joined(separator: ", ") + ")"
      + (onDelete.map { " ON DELETE " + $0.rawValue } ?? "")
      + (onUpdate.map { " ON UPDATE " + $0.rawValue } ?? "")
      + (deferred ? " DEFERRABLE INITIALLY DEFERRED" : "")
  }
#endif
