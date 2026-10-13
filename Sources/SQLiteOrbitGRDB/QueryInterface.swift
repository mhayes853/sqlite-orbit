#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public protocol SQLExpressible { var sqlExpression: SQLExpression { get } }
  public protocol SQLSelectable { var sqlSelection: SQL { get } }
  public protocol SQLOrderingTerm { var sqlOrdering: SQL { get } }
  public protocol ColumnExpression: SQLExpressible, SQLSelectable, SQLOrderingTerm {
    var name: String { get }
  }

  public struct SQLExpression: SQLExpressible, SQLSelectable, SQLOrderingTerm, Sendable {
    let literal: SQL
    public init(sql: String, arguments: StatementArguments = StatementArguments()) {
      literal = SQL(sql: sql, arguments: arguments)
    }
    init(_ literal: SQL) { self.literal = literal }
    init(value: (any DatabaseValueConvertible)?) { literal = SQL(sql: "?", arguments: [value]) }
    public var sqlExpression: Self { self }
    public var sqlSelection: SQL { literal }
    public var sqlOrdering: SQL { literal }
    public var asc: SQLExpression { .init(literal + SQL(sql: " ASC")) }
    public var desc: SQLExpression { .init(literal + SQL(sql: " DESC")) }
    public func forKey(_ key: String) -> SQLExpression {
      .init(literal + SQL(sql: " AS " + quoted(key)))
    }
  }
  public struct Column: ColumnExpression, SQLSelectable, SQLOrderingTerm, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
    public init(_ key: some CodingKey) { self.name = key.stringValue }
    public var sqlExpression: SQLExpression { .init(sql: quoted(name)) }
    public var sqlSelection: SQL { sqlExpression.literal }
    public var sqlOrdering: SQL { sqlExpression.literal }
    public var asc: SQLExpression { sqlExpression.asc }
    public var desc: SQLExpression { sqlExpression.desc }
    public func forKey(_ key: String) -> SQLExpression { sqlExpression.forKey(key) }
    public func set(to value: (any DatabaseValueConvertible)?) -> SQLAssignment {
      SQLAssignment(column: name, value: value?.databaseValue ?? .null)
    }
  }
  public struct AllColumns: SQLSelectable, Sendable {
    public init() {}
    public var sqlSelection: SQL { SQL(sql: "*") }
  }
  public struct SQLAssignment: Sendable {
    let column: String
    let value: DatabaseValue
  }
  private func binary(_ lhs: SQLExpression, _ op: String, _ rhs: SQLExpression) -> SQLExpression {
    .init(SQL(sql: "(") + lhs.literal + SQL(sql: " \(op) ") + rhs.literal + SQL(sql: ")"))
  }
  public func == (lhs: some SQLExpressible, rhs: (any DatabaseValueConvertible)?) -> SQLExpression {
    binary(
      lhs.sqlExpression,
      rhs?.databaseValue.isNull != false ? "IS" : "=",
      SQLExpression(value: rhs)
    )
  }
  public func != (lhs: some SQLExpressible, rhs: (any DatabaseValueConvertible)?) -> SQLExpression {
    binary(
      lhs.sqlExpression,
      rhs?.databaseValue.isNull != false ? "IS NOT" : "<>",
      SQLExpression(value: rhs)
    )
  }
  public func == (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "=", rhs.sqlExpression)
  }
  public func != (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "<>", rhs.sqlExpression)
  }
  public func && (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "AND", rhs.sqlExpression)
  }
  public func || (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "OR", rhs.sqlExpression)
  }
  public prefix func ! (expression: some SQLExpressible) -> SQLExpression {
    .init(SQL(sql: "NOT ") + expression.sqlExpression.literal)
  }
  public func < (lhs: some SQLExpressible, rhs: any DatabaseValueConvertible) -> SQLExpression {
    binary(lhs.sqlExpression, "<", SQLExpression(value: rhs))
  }
  public func <= (lhs: some SQLExpressible, rhs: any DatabaseValueConvertible) -> SQLExpression {
    binary(lhs.sqlExpression, "<=", SQLExpression(value: rhs))
  }
  public func > (lhs: some SQLExpressible, rhs: any DatabaseValueConvertible) -> SQLExpression {
    binary(lhs.sqlExpression, ">", SQLExpression(value: rhs))
  }
  public func >= (lhs: some SQLExpressible, rhs: any DatabaseValueConvertible) -> SQLExpression {
    binary(lhs.sqlExpression, ">=", SQLExpression(value: rhs))
  }
  public func + (lhs: some SQLExpressible, rhs: any DatabaseValueConvertible) -> SQLExpression {
    binary(lhs.sqlExpression, "+", SQLExpression(value: rhs))
  }
  public func - (lhs: some SQLExpressible, rhs: any DatabaseValueConvertible) -> SQLExpression {
    binary(lhs.sqlExpression, "-", SQLExpression(value: rhs))
  }
  public func * (lhs: some SQLExpressible, rhs: any DatabaseValueConvertible) -> SQLExpression {
    binary(lhs.sqlExpression, "*", SQLExpression(value: rhs))
  }
  public func / (lhs: some SQLExpressible, rhs: any DatabaseValueConvertible) -> SQLExpression {
    binary(lhs.sqlExpression, "/", SQLExpression(value: rhs))
  }
  extension SQLExpressible {
    public func like(_ pattern: String) -> SQLExpression {
      binary(sqlExpression, "LIKE", SQLExpression(value: pattern))
    }
  }
  extension Sequence where Element: DatabaseValueConvertible {
    public func contains(_ expression: some SQLExpressible) -> SQLExpression {
      let values = map(\.databaseValue)
      guard !values.isEmpty else { return .init(sql: "0") }
      return .init(
        expression.sqlExpression.literal
          + SQL(
            sql: " IN (" + Array(repeating: "?", count: values.count).joined(separator: ", ") + ")",
            arguments: StatementArguments(values)
          )
      )
    }
  }
  public func count(_ expression: some SQLExpressible) -> SQLExpression {
    .init(SQL(sql: "COUNT(") + expression.sqlExpression.literal + SQL(sql: ")"))
  }
  public func max(_ expression: some SQLExpressible) -> SQLExpression {
    .init(SQL(sql: "MAX(") + expression.sqlExpression.literal + SQL(sql: ")"))
  }
  public func min(_ expression: some SQLExpressible) -> SQLExpression {
    .init(SQL(sql: "MIN(") + expression.sqlExpression.literal + SQL(sql: ")"))
  }

  public protocol FetchRequest {
    associatedtype RowDecoder
    func sql(in db: Database) throws -> SQL
    var cached: Bool { get }
  }
  func decodeRow<T>(_ row: Row, as type: T.Type) throws -> T {
    if type == Row.self { return row.copy() as! T }
    if let record = type as? any FetchableRecord.Type { return try record.init(row: row) as! T }
    if let scalar = type as? any DatabaseValueConvertible.Type,
      let value = scalar.fromDatabaseValue(row.databaseValues[0]) as? T
    {
      return value
    }
    throw RowDecodingError(
      column: row.columnNames.first ?? "",
      databaseValue: row.databaseValues.first ?? .null,
      type: type
    )
  }
  extension FetchRequest {
    public var cached: Bool { false }
    public func fetchCursor(_ db: Database) throws -> AnyCursor<RowDecoder> {
      let sql = try sql(in: db)
      return try db.cursor(sql: sql.sql, arguments: sql.arguments, cached: cached)
        .map { try decodeRow($0, as: RowDecoder.self) }
    }
    public func fetchAll(_ db: Database) throws -> [RowDecoder] { try Array(fetchCursor(db)) }
    public func fetchOne(_ db: Database) throws -> RowDecoder? {
      let sql = try sql(in: db)
      guard
        let row = try db.cursor(sql: sql.sql, arguments: sql.arguments, cached: cached).next()?
          .copy()
      else { return nil }
      if let scalar = RowDecoder.self as? any DatabaseValueConvertible.Type,
        row.databaseValues[0].isNull, scalar.fromDatabaseValue(.null) == nil
      {
        return nil
      }
      return try decodeRow(row, as: RowDecoder.self)
    }
    public func fetchCount(_ db: Database) throws -> Int {
      let sql = try sql(in: db)
      return try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM (\(sql.sql))",
        arguments: sql.arguments
      )
        ?? 0
    }
  }
  public struct SQLRequest<RowDecoder>: FetchRequest, Sendable {
    private let literal: SQL
    public let cached: Bool
    public init(
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      cached: Bool = false
    ) {
      literal = SQL(sql: sql, arguments: arguments)
      self.cached = cached
    }
    public init(literal: SQL, cached: Bool = false) {
      self.literal = literal
      self.cached = cached
    }
    public func sql(in db: Database) throws -> SQL { literal }
    public func asRequest<T>(of type: T.Type) -> SQLRequest<T> {
      .init(literal: literal, cached: cached)
    }
  }
  public struct QueryInterfaceRequest<RowDecoder>: FetchRequest, Sendable {
    let table: String
    var selections: [SQL] = [SQL(sql: "*")]
    var predicates: [SQL] = []
    var ordering: [SQL] = []
    var groups: [SQL] = []
    var havingPredicates: [SQL] = []
    var rowLimit: Int?
    var offset: Int?
    var isDistinct = false
    private var ids: [[RecordKey]] = []
    private var keys: [[[String: RecordKey]]] = []
    private var recordType = RecordKeyEncodingType(RowDecoder.self as? any EncodableRecord.Type)
    init(table: String) { self.table = table }
    public func sql(in db: Database) throws -> SQL {
      var result = SQL(sql: "SELECT " + (isDistinct ? "DISTINCT " : ""))
      result = result + joined(selections, separator: ", ") + SQL(sql: " FROM " + quoted(table))
      result = result + (try condition(in: db))
      if !groups.isEmpty {
        result = result + SQL(sql: " GROUP BY ") + joined(groups, separator: ", ")
      }
      if !havingPredicates.isEmpty {
        result = result + SQL(sql: " HAVING ") + joined(havingPredicates, separator: " AND ")
      }
      if !ordering.isEmpty {
        result = result + SQL(sql: " ORDER BY ") + joined(ordering, separator: ", ")
      }
      if let rowLimit {
        result = result + SQL(sql: " LIMIT \(rowLimit)" + (offset.map { " OFFSET \($0)" } ?? ""))
      }
      return result
    }
    func condition(in db: Database) throws -> SQL {
      var predicates = predicates
      for ids in ids {
        let pk = try db.primaryKey(table)
        guard pk.columns.count == 1 else {
          throw DatabaseError(message: "a scalar key requires a single-column primary key")
        }
        let values = try ids.map {
          try $0.encoded(column: pk.columns[0], record: recordType.record)
        }
        predicates.append(values.contains(Column(pk.columns[0])).literal)
      }
      for keys in keys {
        let branches = try keys.map { key in
          try joined(
            key.sorted { $0.key < $1.key }
              .map {
                (Column($0.key) == (try $0.value.encoded(column: $0.key, record: recordType.record)))
                .literal
              },
            separator: " AND "
          )
        }
        predicates.append(
          branches.isEmpty
            ? SQL(sql: "0")
            : SQL(sql: "(")
              + joined(branches.map { SQL(sql: "(") + $0 + SQL(sql: ")") }, separator: " OR ")
              + SQL(sql: ")")
        )
      }
      return predicates.isEmpty
        ? SQL(sql: "") : SQL(sql: " WHERE ") + joined(predicates, separator: " AND ")
    }
    public func filter(_ predicate: some SQLExpressible) -> Self {
      var result = self
      result.predicates.append(predicate.sqlExpression.literal)
      return result
    }
    public func filter(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      var result = self
      result.predicates.append(SQL(sql: "(" + sql + ")", arguments: arguments))
      return result
    }
    public func filter(key: (any DatabaseValueConvertible)?) -> Self { filter(id: key) }
    public func filter<S: Sequence>(keys: S) -> Self where S.Element: DatabaseValueConvertible {
      filter(ids: keys)
    }
    public func filter(id: (any DatabaseValueConvertible)?) -> Self {
      var result = self
      result.ids.append(id.map { [RecordKey($0)] } ?? [])
      return result
    }
    public func filter<S: Sequence>(ids: S) -> Self where S.Element: DatabaseValueConvertible {
      var result = self
      result.ids.append(ids.map { RecordKey($0) })
      return result
    }
    public func filter(key: [String: (any DatabaseValueConvertible)?]) -> Self {
      var result = self
      result.keys.append([key.mapValues { $0.map(RecordKey.init) ?? .value(.null) }])
      return result
    }
    public func order(_ terms: any SQLOrderingTerm...) -> Self {
      var result = self
      result.ordering = terms.map(\.sqlOrdering)
      return result
    }
    public func order(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      var result = self
      result.ordering = [SQL(sql: sql, arguments: arguments)]
      return result
    }
    public func limit(_ limit: Int, offset: Int? = nil) -> Self {
      var result = self
      result.rowLimit = limit
      result.offset = offset
      return result
    }
    public func select(_ selections: any SQLSelectable...) -> Self {
      var result = self
      result.selections = selections.map(\.sqlSelection)
      return result
    }
    public func select<T>(_ selections: any SQLSelectable..., as type: T.Type)
      -> QueryInterfaceRequest<T>
    {
      var result = asRequest(of: type)
      result.selections = selections.map(\.sqlSelection)
      return result
    }
    public func distinct() -> Self {
      var result = self
      result.isDistinct = true
      return result
    }
    public func group(_ expressions: any SQLExpressible...) -> Self {
      var result = self
      result.groups = expressions.map { $0.sqlExpression.literal }
      return result
    }
    public func having(_ expression: some SQLExpressible) -> Self {
      var result = self
      result.havingPredicates.append(expression.sqlExpression.literal)
      return result
    }
    public func asRequest<T>(of type: T.Type) -> QueryInterfaceRequest<T> {
      var result = QueryInterfaceRequest<T>(table: table)
      result.selections = selections
      result.predicates = predicates
      result.ordering = ordering
      result.groups = groups
      result.havingPredicates = havingPredicates
      result.rowLimit = rowLimit
      result.offset = offset
      result.isDistinct = isDistinct
      result.ids = ids
      result.keys = keys
      result.recordType = recordType
      return result
    }
    private func mutationCondition(in db: Database) throws -> SQL {
      guard groups.isEmpty && havingPredicates.isEmpty else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "grouped requests do not support bulk writes"
        )
      }
      return try condition(in: db)
    }
    private func mutationSuffix() -> SQL {
      var result = SQL(sql: "")
      if !ordering.isEmpty {
        result = result + SQL(sql: " ORDER BY ") + joined(ordering, separator: ", ")
      }
      if let rowLimit {
        result = result + SQL(sql: " LIMIT \(rowLimit)" + (offset.map { " OFFSET \($0)" } ?? ""))
      }
      return result
    }
    @discardableResult public func deleteAll(_ db: Database) throws -> Int {
      let sql =
        SQL(sql: "DELETE FROM " + quoted(table)) + (try mutationCondition(in: db))
        + mutationSuffix()
      try db.execute(literal: sql)
      return db.changesCount
    }
    @discardableResult public func updateAll(_ db: Database, _ assignments: SQLAssignment...) throws
      -> Int
    {
      guard !assignments.isEmpty else { return 0 }
      let clauses = assignments.map { SQL(sql: quoted($0.column) + " = ?", arguments: [$0.value]) }
      let sql =
        SQL(sql: "UPDATE " + quoted(table) + " SET ") + joined(clauses, separator: ", ")
        + (try mutationCondition(in: db)) + mutationSuffix()
      try db.execute(literal: sql)
      return db.changesCount
    }
  }
  func joined(_ fragments: [SQL], separator: String) -> SQL {
    fragments.enumerated()
      .reduce(SQL(sql: "")) { $0 + SQL(sql: $1.offset == 0 ? "" : separator) + $1.element }
  }
  public protocol TableRecord {
    static var databaseTableName: String { get }
    static var databaseSelection: [any SQLSelectable] { get }
  }
  extension TableRecord {
    public static var databaseTableName: String {
      let name = String(describing: Self.self)
      return name.prefix(1).lowercased() + name.dropFirst()
    }
    public static var databaseSelection: [any SQLSelectable] { [AllColumns()] }
    public static func all() -> QueryInterfaceRequest<Self> {
      var request = QueryInterfaceRequest<Self>(table: databaseTableName)
      request.selections = databaseSelection.map(\.sqlSelection)
      return request
    }
    public static func none() -> QueryInterfaceRequest<Self> { all().filter(sql: "0") }
    public static func filter(_ predicate: some SQLExpressible) -> QueryInterfaceRequest<Self> {
      all().filter(predicate)
    }
    public static func filter(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<Self>
    { all().filter(sql: sql, arguments: arguments) }
    public static func filter(key: (any DatabaseValueConvertible)?) -> QueryInterfaceRequest<Self> {
      all().filter(key: key)
    }
    public static func filter<S: Sequence>(keys: S) -> QueryInterfaceRequest<Self>
    where S.Element: DatabaseValueConvertible { all().filter(keys: keys) }
    public static func filter(id: (any DatabaseValueConvertible)?) -> QueryInterfaceRequest<Self> {
      all().filter(id: id)
    }
    public static func filter<S: Sequence>(ids: S) -> QueryInterfaceRequest<Self>
    where S.Element: DatabaseValueConvertible { all().filter(ids: ids) }
    public static func order(_ terms: any SQLOrderingTerm...) -> QueryInterfaceRequest<Self> {
      var result = all()
      result.ordering = terms.map(\.sqlOrdering)
      return result
    }
    public static func limit(_ limit: Int, offset: Int? = nil) -> QueryInterfaceRequest<Self> {
      all().limit(limit, offset: offset)
    }
    public static func select(_ selections: any SQLSelectable...) -> QueryInterfaceRequest<Self> {
      var result = all()
      result.selections = selections.map(\.sqlSelection)
      return result
    }
    public static func filter(key: [String: (any DatabaseValueConvertible)?])
      -> QueryInterfaceRequest<Self>
    { all().filter(key: key) }
    public static func fetchCount(_ db: Database) throws -> Int { try all().fetchCount(db) }
    @discardableResult public static func deleteAll(_ db: Database) throws -> Int {
      try all().deleteAll(db)
    }
    @discardableResult public static func deleteOne(
      _ db: Database,
      id: (any DatabaseValueConvertible)?
    ) throws -> Bool { try all().filter(id: id).deleteAll(db) > 0 }
    public static func exists(_ db: Database, id: (any DatabaseValueConvertible)?) throws -> Bool {
      try all().filter(id: id).fetchCount(db) > 0
    }
  }

  extension ColumnExpression {
    public var sqlSelection: SQL { sqlExpression.literal }
    public var sqlOrdering: SQL { sqlExpression.literal }
    public func set(to value: (any DatabaseValueConvertible)?) -> SQLAssignment {
      Column(name).set(to: value)
    }
    public var sqlExpression: SQLExpression { Column(name).sqlExpression }
    public var asc: SQLExpression { sqlExpression.asc }
    public var desc: SQLExpression { sqlExpression.desc }
  }
  extension ColumnExpression where Self: RawRepresentable, RawValue == String {
    public var name: String { rawValue }
  }
  extension SQLRequest: ExpressibleByStringInterpolation {
    public typealias StringInterpolation = SQL.StringInterpolation
    public init(stringLiteral value: String) { self.init(sql: value) }
    public init(stringInterpolation: StringInterpolation) {
      self.init(literal: SQL(stringInterpolation: stringInterpolation))
    }
  }
  public struct Table<RowDecoder>: Sendable {
    public let tableName: String
    public init(_ tableName: String) { self.tableName = tableName }
    public func all() -> QueryInterfaceRequest<RowDecoder> {
      QueryInterfaceRequest(table: tableName)
    }
    public func filter(_ expression: some SQLExpressible) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(expression)
    }
    public func filter(id: (any DatabaseValueConvertible)?) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(id: id)
    }
    public func filter(key: (any DatabaseValueConvertible)?) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(key: key)
    }
    public func fetchCount(_ db: Database) throws -> Int { try all().fetchCount(db) }
    public func fetchAll(_ db: Database) throws -> [RowDecoder] { try all().fetchAll(db) }
    public func fetchOne(_ db: Database) throws -> RowDecoder? { try all().fetchOne(db) }
  }
  extension Table where RowDecoder == Row {
    public init(_ tableName: String) { self.tableName = tableName }
  }
  extension FetchRequest where RowDecoder == Row {
    public func fetchCursor(_ db: Database) throws -> RowCursor {
      let sql = try sql(in: db)
      return try db.cursor(sql: sql.sql, arguments: sql.arguments, cached: cached)
    }
  }
  extension FetchableRecord {
    public static func fetchOne(_ db: Database, _ request: some FetchRequest) throws -> Self? {
      let sql = try request.sql(in: db)
      return try fetchOne(db, sql: sql.sql, arguments: sql.arguments)
    }
    public static func fetchAll(_ db: Database, _ request: some FetchRequest) throws -> [Self] {
      let sql = try request.sql(in: db)
      return try fetchAll(db, sql: sql.sql, arguments: sql.arguments)
    }
  }
  extension Row {
    public static func fetchOne(_ db: Database, _ request: some FetchRequest) throws -> Row? {
      let sql = try request.sql(in: db)
      return try fetchOne(db, sql: sql.sql, arguments: sql.arguments)
    }
    public static func fetchAll(_ db: Database, _ request: some FetchRequest) throws -> [Row] {
      let sql = try request.sql(in: db)
      return try fetchAll(db, sql: sql.sql, arguments: sql.arguments)
    }
    public static func fetchCursor(_ db: Database, _ request: some FetchRequest) throws -> RowCursor
    {
      let sql = try request.sql(in: db)
      return try fetchCursor(db, sql: sql.sql, arguments: sql.arguments)
    }
  }

  // A metatype is immutable identity; no record instance crosses a concurrency boundary here.
  private struct RecordKeyEncodingType: @unchecked Sendable {
    let record: (any EncodableRecord.Type)?
    init(_ record: (any EncodableRecord.Type)?) { self.record = record }
  }
  private enum RecordKey: Sendable {
    case value(DatabaseValue)
    case date(Date)
    case data(Data)
    case uuid(UUID)
    init(_ value: any DatabaseValueConvertible) {
      if let date = value as? Date {
        self = .date(date)
      } else if let data = value as? Data {
        self = .data(data)
      } else if let uuid = value as? UUID {
        self = .uuid(uuid)
      } else {
        self = .value(value.databaseValue)
      }
    }
    func encoded(column: String, record: (any EncodableRecord.Type)?) throws -> DatabaseValue {
      switch self {
      case .value(let value): return value
      case .date(let date):
        return encodeDatabaseDate(
          date,
          strategy: record?.databaseDateEncodingStrategy(for: column) ?? .deferredToDate
        )
      case .data(let data):
        return try encodeDatabaseData(
          data,
          strategy: record?.databaseDataEncodingStrategy(for: column) ?? .deferredToData
        )
      case .uuid(let uuid):
        return encodeDatabaseUUID(
          uuid,
          strategy: record?.databaseUUIDEncodingStrategy(for: column) ?? .deferredToUUID
        )
      }
    }
  }

#endif
