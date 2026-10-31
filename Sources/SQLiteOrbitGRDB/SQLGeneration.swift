#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - SQLGenerationContext

  /// Collects statement arguments and resolves table aliases while SQL is generated.
  final class SQLGenerationContext {
    private final class Sink {
      var arguments = StatementArguments()
      let literalValues: Bool

      init(literalValues: Bool) {
        self.literalValues = literalValues
      }
    }

    private let database: Database?
    private let sink: Sink
    private let parent: SQLGenerationContext?
    private let resolvedNames: [TableAliasBase: String]
    private let ownAliases: Set<TableAliasBase>
    private let ctes: [String: SQLCTE]

    /// Creates a root context. Without a database, schema-dependent SQL cannot be generated.
    init(
      _ db: Database?,
      literalValues: Bool = false,
      aliases: [TableAliasBase] = [],
      ctes: [(String, SQLCTE)] = []
    ) {
      database = db
      sink = Sink(literalValues: literalValues)
      parent = nil
      resolvedNames = Self.resolveNames(aliases)
      ownAliases = Set(aliases)
      self.ctes = Dictionary(ctes.map { ($0.0.lowercased(), $0.1) }, uniquingKeysWith: { $1 })
    }

    private init(parent: SQLGenerationContext, aliases: [TableAliasBase], ctes: [(String, SQLCTE)])
    {
      database = parent.database
      sink = parent.sink
      self.parent = parent
      resolvedNames = Self.resolveNames(aliases)
      ownAliases = Set(aliases)
      self.ctes = Dictionary(ctes.map { ($0.0.lowercased(), $0.1) }, uniquingKeysWith: { $1 })
    }

    func subqueryContext(aliases: [TableAliasBase] = [], ctes: [(String, SQLCTE)] = [])
      -> SQLGenerationContext
    {
      SQLGenerationContext(parent: self, aliases: aliases, ctes: ctes)
    }

    var arguments: StatementArguments { sink.arguments }

    var db: Database? { database }

    func requireDatabase() throws -> Database {
      guard let database else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "this SQL requires a database connection"
        )
      }
      return database
    }

    /// Appends the arguments of raw SQL text.
    func appendLiteralArguments(_ arguments: StatementArguments) throws {
      if arguments.values.isEmpty && arguments.namedValues.isEmpty { return }
      if sink.literalValues {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "Not implemented: turning an SQL parameter into an SQL literal value"
        )
      }
      sink.arguments = sink.arguments &+ arguments
    }

    /// Renders a value as a statement parameter, or as an SQL literal in literal mode.
    func valueSQL(_ value: DatabaseValue) throws -> String {
      if value.isNull { return "NULL" }
      if !sink.literalValues {
        sink.arguments = sink.arguments &+ StatementArguments([value])
        return "?"
      }
      return try requireDatabase().quotedLiteral(value)
    }

    func qualifier(for alias: TableAliasBase) -> String? {
      if alias.hasUserName { return alias.identityName }
      if !ownAliases.contains(alias) || ownAliases.count > 1 { return resolvedName(for: alias) }
      return nil
    }

    func resolvedName(for alias: TableAliasBase) -> String {
      if let name = resolvedNames[alias] { return name }
      return parent?.resolvedName(for: alias) ?? alias.identityName
    }

    func aliasName(for alias: TableAliasBase) -> String? {
      let name = resolvedName(for: alias)
      return name != alias.tableName ? name : nil
    }

    func cte(named name: String) -> SQLCTE? {
      ctes[name.lowercased()] ?? parent?.cte(named: name)
    }

    func columnNames(in table: String) throws -> [String] {
      if let cte = cte(named: table) {
        return try cte.columnNames(requireDatabase())
      }
      return try requireDatabase().columns(in: table).map(\.name)
    }

    func columnCount(in table: String, excluding excluded: Set<String>) throws -> Int {
      if excluded.isEmpty, let cte = cte(named: table) {
        return try cte.columnCount(requireDatabase())
      }
      return try columnNames(in: table).filter { !excluded.contains($0.lowercased()) }.count
    }

    private static func resolveNames(_ aliases: [TableAliasBase]) -> [TableAliasBase: String] {
      let groups = Dictionary(grouping: aliases) { $0.identityName.lowercased() }
      var taken = Set(groups.filter { $0.value.count == 1 }.keys)
      var result: [TableAliasBase: String] = [:]
      for (_, group) in groups.sorted(by: { $0.key < $1.key }) where group.count > 1 {
        var index = 1
        for alias in group where !alias.hasUserName {
          let radical = String(alias.identityName.reversed().drop(while: \.isNumber).reversed())
          var name: String
          repeat {
            name = "\(radical)\(index)"
            index += 1
          } while taken.contains(name.lowercased())
          taken.insert(name.lowercased())
          result[alias] = name
        }
      }
      return result
    }
  }

  // MARK: - Table aliases

  /// A reference to a table in a request, used to qualify columns.
  public class TableAliasBase: Hashable, @unchecked Sendable {
    private enum State {
      case undefined(userName: String?)
      case table(tableName: String, userName: String?)
      case proxy(TableAliasBase)
    }

    private var state: State

    init(name: String? = nil) {
      state = .undefined(userName: name)
    }

    init(tableName: String, userName: String? = nil) {
      state = .table(tableName: tableName, userName: userName)
    }

    private var root: TableAliasBase {
      if case .proxy(let base) = state { return base.root }
      return self
    }

    var identityName: String { userName ?? tableName }

    var hasUserName: Bool { userName != nil }

    var tableName: String {
      switch state {
      case .undefined: preconditionFailure("Undefined alias has no table name")
      case .table(let tableName, _): return tableName
      case .proxy(let base): return base.tableName
      }
    }

    var hasTableName: Bool {
      switch state {
      case .undefined: return false
      case .table: return true
      case .proxy(let base): return base.hasTableName
      }
    }

    private var userName: String? {
      switch state {
      case .undefined(let userName): return userName
      case .table(_, let userName): return userName
      case .proxy(let base): return base.userName
      }
    }

    private func setUserName(_ name: String) {
      switch state {
      case .undefined: state = .undefined(userName: name)
      case .table(let tableName, _): state = .table(tableName: tableName, userName: name)
      case .proxy(let base): base.setUserName(name)
      }
    }

    func setTableName(_ tableName: String) {
      switch state {
      case .undefined(let userName):
        state = .table(tableName: tableName, userName: userName)
      case .table(let initial, _):
        precondition(
          tableName.lowercased() == initial.lowercased(),
          "A TableAlias most not be used to refer to multiple tables"
        )
      case .proxy(let base):
        base.setTableName(tableName)
      }
    }

    /// Merges two aliases of the same table, or returns nil if they conflict.
    func merged(with other: TableAliasBase) -> TableAliasBase? {
      if self === other { return self }
      let root = self.root
      let otherRoot = other.root
      guard case .table(let tableName, let userName) = root.state,
        case .table(let otherTableName, let otherUserName) = otherRoot.state,
        tableName == otherTableName
      else {
        return nil
      }
      if let userName, let otherUserName, userName != otherUserName { return nil }
      root.becomeProxy(of: otherRoot)
      return otherRoot
    }

    func becomeProxy(of base: TableAliasBase) {
      if self === base { return }
      switch state {
      case .undefined(let userName), .table(_, let userName):
        if let userName { base.setUserName(userName) }
        state = .proxy(base)
      case .proxy(let selfBase):
        selfBase.becomeProxy(of: base)
      }
    }

    public static func == (lhs: TableAliasBase, rhs: TableAliasBase) -> Bool {
      lhs.root === rhs.root
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(root))
    }

    /// Qualifies a selection with this alias.
    public subscript(_ selectable: some SQLSelectable) -> SQLSelection {
      selectable.sqlSelection.qualified(with: self)
    }

    /// Qualifies an expression with this alias.
    public subscript(_ expression: some SQLSpecificExpressible & SQLSelectable & SQLOrderingTerm)
      -> SQLExpression
    {
      expression.sqlExpression.qualified(with: self)
    }

    /// Qualifies an ordering term with this alias.
    public subscript(_ ordering: some SQLOrderingTerm) -> SQLOrdering {
      ordering.sqlOrdering.qualified(with: self)
    }

    /// A column of the aliased table.
    public subscript(_ column: String) -> SQLExpression {
      .qualifiedColumn(column, self)
    }
  }

  /// A table alias, for referring to a table in requests that join several tables.
  @dynamicMemberLookup
  public final class TableAlias<RowDecoder>: TableAliasBase, @unchecked Sendable {
    public init(name: String? = nil) where RowDecoder == Void {
      super.init(name: name)
    }

    public init(name: String? = nil, for record: RowDecoder.Type = RowDecoder.self) {
      super.init(name: name)
    }

    init(tableName: String, userName: String? = nil) where RowDecoder == Void {
      super.init(tableName: tableName, userName: userName)
    }

    init(root: TableAliasBase) {
      super.init()
      becomeProxy(of: root)
    }

    /// An expression that is true when the aliased table has a matching joined row.
    public var exists: SQLExpression {
      .qualifiedExists(self)
    }
  }

  extension TableAlias where RowDecoder: TableRecord {
    public typealias DatabaseComponents = RowDecoder.DatabaseComponents

    public subscript<T: SQLSelectable>(dynamicMember keyPath: KeyPath<DatabaseComponents, T>)
      -> SQLSelection
    {
      self[RowDecoder.databaseComponents[keyPath: keyPath]]
    }

    public subscript<T: SQLSpecificExpressible & SQLSelectable & SQLOrderingTerm>(
      dynamicMember keyPath: KeyPath<DatabaseComponents, T>
    ) -> SQLExpression {
      self[RowDecoder.databaseComponents[keyPath: keyPath]]
    }

    public subscript<T: SQLOrderingTerm>(dynamicMember keyPath: KeyPath<DatabaseComponents, T>)
      -> SQLOrdering
    {
      self[RowDecoder.databaseComponents[keyPath: keyPath]]
    }
  }

  // MARK: - SQLSelection

  /// An element of a query selection.
  public struct SQLSelection: SQLSelectable, Sendable {
    enum Node: Sendable {
      case allColumns
      case qualifiedAllColumns(TableAliasBase)
      case allColumnsExcluding(Set<String>)
      case qualifiedAllColumnsExcluding(TableAliasBase, Set<String>)
      case expression(SQLExpression)
      case aliasedExpression(SQLExpression, String)
      case literal(SQL)
    }

    var node: Node

    public var sqlSelection: SQLSelection { self }

    static let allColumns = SQLSelection(node: .allColumns)

    static func expression(_ expression: SQLExpression) -> Self {
      .init(node: .expression(expression))
    }

    static func aliasedExpression(_ expression: SQLExpression, _ name: String) -> Self {
      .init(node: .aliasedExpression(expression, name))
    }

    static func literal(_ sql: SQL) -> Self { .init(node: .literal(sql)) }

    static func qualifiedAllColumns(_ alias: TableAliasBase) -> Self {
      .init(node: .qualifiedAllColumns(alias))
    }

    func sql(_ context: SQLGenerationContext) throws -> String {
      switch node {
      case .allColumns:
        return "*"
      case .allColumnsExcluding(let excluded):
        // Unqualified exclusions appear outside requests, such as in SQL interpolation.
        if excluded.isEmpty { return "*" }
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "allColumns(excluding:) requires a table"
        )
      case .qualifiedAllColumns(let alias):
        if let qualifier = context.qualifier(for: alias) { return quoted(qualifier) + ".*" }
        return "*"
      case .qualifiedAllColumnsExcluding(let alias, let excluded):
        let names = try context.columnNames(in: alias.tableName)
        let remaining = names.filter { !excluded.contains($0.lowercased()) }
        if remaining.count == names.count {
          if let qualifier = context.qualifier(for: alias) { return quoted(qualifier) + ".*" }
          return "*"
        }
        return try remaining.map { try SQLExpression.qualifiedColumn($0, alias).sql(context) }
          .joined(separator: ", ")
      case .expression(let expression):
        return try expression.sql(context)
      case .aliasedExpression(let expression, let name):
        return try expression.sql(context) + " AS " + quoted(name)
      case .literal(let literal):
        return try literal.sql(context)
      }
    }

    func qualified(with alias: TableAliasBase) -> SQLSelection {
      switch node {
      case .qualifiedAllColumns, .qualifiedAllColumnsExcluding: return self
      case .allColumns: return .init(node: .qualifiedAllColumns(alias))
      case .allColumnsExcluding(let excluded):
        return .init(node: .qualifiedAllColumnsExcluding(alias, excluded))
      case .expression(let e): return .expression(e.qualified(with: alias))
      case .aliasedExpression(let e, let name):
        return .aliasedExpression(e.qualified(with: alias), name)
      case .literal(let sql): return .literal(sql.qualified(with: alias))
      }
    }

    /// The number of columns, when it can be known.
    func columnCount(_ context: SQLGenerationContext) throws -> Int? {
      switch node {
      case .allColumns, .allColumnsExcluding, .literal: return nil
      case .qualifiedAllColumns(let alias):
        return try context.columnCount(in: alias.tableName, excluding: [])
      case .qualifiedAllColumnsExcluding(let alias, let excluded):
        return try context.columnCount(in: alias.tableName, excluding: excluded)
      case .expression, .aliasedExpression: return 1
      }
    }

    enum Count {
      case all
      case distinct(SQLExpression)
    }

    func count(distinct: Bool) -> Count? {
      switch node {
      case .allColumns, .allColumnsExcluding: return distinct ? nil : .all
      case .qualifiedAllColumns, .qualifiedAllColumnsExcluding, .literal: return nil
      case .expression(let e), .aliasedExpression(let e, _): return distinct ? .distinct(e) : .all
      }
    }

    var isAggregate: Bool {
      switch node {
      case .expression(let e), .aliasedExpression(let e, _): return e.isAggregate
      default: return false
      }
    }

    var requiresTrivialCount: Bool {
      switch node {
      case .aliasedExpression, .literal: return true
      default: return false
      }
    }
  }

  /// Selects all columns of a table.
  public struct AllColumns: SQLSelectable, Sendable {
    public init() {}

    public var sqlSelection: SQLSelection { .allColumns }
  }

  /// Selects all columns of a table but the excluded ones.
  public struct AllColumnsExcluding: SQLSelectable, Sendable {
    var excludedColumns: Set<String>

    public init(_ excludedColumns: some Collection<String>) {
      self.excludedColumns = Set(excludedColumns.map { $0.lowercased() })
    }

    public var sqlSelection: SQLSelection { .init(node: .allColumnsExcluding(excludedColumns)) }
  }

  extension SQLSelectable where Self == AllColumns {
    /// All columns of the table.
    public static var allColumns: AllColumns { AllColumns() }
  }

  extension SQLSelectable where Self == AllColumnsExcluding {
    /// All columns of the table but the excluded ones.
    public static func allColumns(excluding excludedColumns: some Collection<String>) -> Self {
      AllColumnsExcluding(excludedColumns)
    }

    /// All columns of the table but the excluded ones.
    public static func allColumns(excluding excludedColumns: some Collection<any ColumnExpression>)
      -> Self
    {
      AllColumnsExcluding(excludedColumns.map(\.name))
    }
  }

  extension SQLSelectable where Self == Column {
    /// The hidden rowID column.
    public static var rowID: Self { Column.rowID }
  }

  extension SQLSpecificExpressible {
    /// Selects the expression with a result column name.
    public func forKey(_ key: String) -> SQLSelection {
      .aliasedExpression(sqlExpression, key)
    }

    /// Selects the expression with a result column name.
    public func forKey(_ key: some CodingKey) -> SQLSelection {
      forKey(key.stringValue)
    }
  }

  // MARK: - SQLOrdering

  /// An ordering term, such as an expression sorted in descending order.
  public struct SQLOrdering: SQLOrderingTerm, Sendable {
    enum Node: Sendable {
      case expression(SQLExpression)
      case asc(SQLExpression)
      case desc(SQLExpression)
      case ascNullsLast(SQLExpression)
      case descNullsFirst(SQLExpression)
      case literal(SQL)
    }

    var node: Node

    public var sqlOrdering: SQLOrdering { self }

    static func expression(_ e: SQLExpression) -> Self { .init(node: .expression(e)) }

    static func literal(_ sql: SQL) -> Self { .init(node: .literal(sql)) }

    func sql(_ context: SQLGenerationContext) throws -> String {
      switch node {
      case .expression(let e): return try e.sql(context)
      case .asc(let e): return try e.sql(context) + " ASC"
      case .desc(let e): return try e.sql(context) + " DESC"
      case .ascNullsLast(let e): return try e.sql(context) + " ASC NULLS LAST"
      case .descNullsFirst(let e): return try e.sql(context) + " DESC NULLS FIRST"
      case .literal(let sql): return try sql.sql(context)
      }
    }

    func qualified(with alias: TableAliasBase) -> SQLOrdering {
      switch node {
      case .expression(let e): return .init(node: .expression(e.qualified(with: alias)))
      case .asc(let e): return .init(node: .asc(e.qualified(with: alias)))
      case .desc(let e): return .init(node: .desc(e.qualified(with: alias)))
      case .ascNullsLast(let e): return .init(node: .ascNullsLast(e.qualified(with: alias)))
      case .descNullsFirst(let e): return .init(node: .descNullsFirst(e.qualified(with: alias)))
      case .literal(let sql): return .literal(sql.qualified(with: alias))
      }
    }

    /// The reversed ordering, or nil for raw SQL orderings.
    var reversed: SQLOrdering? {
      switch node {
      case .expression(let e), .asc(let e): return .init(node: .desc(e))
      case .desc(let e): return .init(node: .asc(e))
      case .ascNullsLast(let e): return .init(node: .descNullsFirst(e))
      case .descNullsFirst(let e): return .init(node: .ascNullsLast(e))
      case .literal: return nil
      }
    }
  }

  extension SQLSpecificExpressible {
    /// Ascending order.
    public var asc: SQLOrdering { .init(node: .asc(sqlExpression)) }

    /// Descending order.
    public var desc: SQLOrdering { .init(node: .desc(sqlExpression)) }

    /// Ascending order, with NULL values last.
    public var ascNullsLast: SQLOrdering { .init(node: .ascNullsLast(sqlExpression)) }

    /// Descending order, with NULL values first.
    public var descNullsFirst: SQLOrdering { .init(node: .descNullsFirst(sqlExpression)) }
  }

  // MARK: - SQLCollection

  /// The right-hand side of an `IN` operator.
  struct SQLCollection: Sendable {
    enum Node: Sendable {
      case array([SQLExpression])
      case subquery(SQLSubquery)
      case table(String)
    }

    var node: Node

    static func array(_ expressions: [SQLExpression]) -> Self { .init(node: .array(expressions)) }

    static func subquery(_ subquery: SQLSubquery) -> Self { .init(node: .subquery(subquery)) }

    static func table(_ name: String) -> Self { .init(node: .table(name)) }

    var expressions: [SQLExpression]? {
      if case .array(let expressions) = node { return expressions }
      return nil
    }

    func qualified(with alias: TableAliasBase) -> SQLCollection {
      if case .array(let expressions) = node {
        return .array(expressions.map { $0.qualified(with: alias) })
      }
      return self
    }

    func sql(_ context: SQLGenerationContext) throws -> String {
      switch node {
      case .array(let expressions):
        return try "(" + expressions.map { try $0.sql(context) }.joined(separator: ", ") + ")"
      case .subquery(let subquery):
        return try "(" + subquery.sql(context) + ")"
      case .table(let name):
        return quoted(name)
      }
    }

    func contains(_ value: SQLExpression) -> SQLExpression {
      guard case .array(let expressions) = node else { return .in(value, self) }
      guard let first = expressions.first else { return false.sqlExpression }
      return expressions.count == 1 ? .compare(.equal, value, first) : .in(value, self)
    }
  }

  // MARK: - SQLSubquery

  /// A subquery, built from a request or from raw SQL.
  public struct SQLSubquery: Sendable {
    enum Node: Sendable {
      case literal(SQL)
      case relation(SQLRelation)
      case deferred(@Sendable (Database) throws -> SQL)
    }

    var node: Node

    static func literal(_ sql: SQL) -> Self { .init(node: .literal(sql)) }

    static func relation(_ relation: SQLRelation) -> Self { .init(node: .relation(relation)) }

    func sql(_ context: SQLGenerationContext) throws -> String {
      switch node {
      case .literal(let sql):
        return try sql.sql(context)
      case .relation(let relation):
        return try SQLQueryGenerator(relation: relation).requestSQL(context)
      case .deferred(let makeSQL):
        return try makeSQL(context.requireDatabase()).sql(context)
      }
    }

    func columnCount(_ db: Database) throws -> Int {
      switch node {
      case .relation(let relation):
        return try SQLQueryGenerator(relation: relation).columnCount(db)
      case .literal, .deferred:
        let context = SQLGenerationContext(db)
        let sql = try sql(context)
        return try db.makeStatement(sql: sql).columnCount
      }
    }

    func columnNames(_ db: Database) throws -> [String] {
      let context = SQLGenerationContext(db)
      let sql = try sql(context)
      return try db.makeStatement(sql: sql).columnNames
    }
  }

  /// A type that can be used as a subquery.
  public protocol SQLSubqueryable: SQLSpecificExpressible {
    var sqlSubquery: SQLSubquery { get }
  }

  extension SQLSubquery: SQLSubqueryable {
    public var sqlSubquery: SQLSubquery { self }
  }

  extension SQLSubqueryable {
    public var sqlExpression: SQLExpression { .subquery(sqlSubquery) }

    /// An expression that tests whether the subquery contains a value.
    public func contains(_ element: some SQLExpressible) -> SQLExpression {
      SQLCollection.subquery(sqlSubquery).contains(element.sqlExpression)
    }

    /// An expression that tests whether the subquery returns any row.
    public func exists() -> SQLExpression {
      .exists(sqlSubquery)
    }
  }

  /// Wraps a non-Sendable value that is only used synchronously during SQL generation.
  struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
  }
#endif
