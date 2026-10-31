#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - FetchRequest

  /// A request that knows the type of fetched values.
  public protocol TypedRequest<RowDecoder> {
    associatedtype RowDecoder
  }

  /// A request that fetches rows, values, or records.
  public protocol FetchRequest<RowDecoder>: SQLSubqueryable {
    associatedtype RowDecoder

    /// The SQL of the request.
    func sql(in db: Database) throws -> SQL

    var cached: Bool { get }

    func makePreparedRequest(
      _ db: Database,
      forSingleResult singleResult: Bool
    ) throws -> PreparedRequest

    /// The number of rows fetched by the request.
    func fetchCount(_ db: Database) throws -> Int
  }

  func decodeRow<T>(_ row: Row, as type: T.Type) throws -> T {
    if type == Row.self {
      return row.copy() as! T
    }
    if let record = type as? any FetchableRecord.Type {
      return try record.init(row: row) as! T
    }
    if let scalar = type as? any DatabaseValueConvertible.Type,
      let first = row.databaseValues.first,
      let value = scalar.fromDatabaseValue(first) as? T
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
    public var cached: Bool {
      false
    }

    public var sqlSubquery: SQLSubquery {
      let request = UncheckedSendable(value: self)
      return SQLSubquery(node: .deferred { try request.value.sql(in: $0) })
    }

    public func fetchCursor(_ db: Database) throws -> AnyCursor<RowDecoder> {
      AnyCursor(try Row.fetchCursor(db, self).map { try decodeRow($0, as: RowDecoder.self) })
    }

    public func fetchAll(_ db: Database) throws -> [RowDecoder] {
      try Row.fetchAllRows(db, self).map { try decodeRow($0, as: RowDecoder.self) }
    }

    public func fetchOne(_ db: Database) throws -> RowDecoder? {
      guard let row = try Row.fetchOneRow(db, self) else { return nil }
      if let scalar = RowDecoder.self as? any DatabaseValueConvertible.Type,
        row.databaseValues.first?.isNull == true, scalar.fromDatabaseValue(.null) == nil
      {
        return nil
      }
      return try decodeRow(row, as: RowDecoder.self)
    }

    public func fetchCount(_ db: Database) throws -> Int {
      let request = SQLRequest<Int>(literal: "SELECT COUNT(*) FROM (\(sqlSubquery))")
      return try request.fetchOne(db) ?? 0
    }
  }

  // MARK: - SQLRequest

  /// A request built from raw SQL.
  public struct SQLRequest<RowDecoder>: FetchRequest, Sendable {
    let literal: SQL
    public let cached: Bool
    public var adapter: (any RowAdapter)?

    public init(
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil,
      cached: Bool = false
    ) {
      literal = SQL(sql: sql, arguments: arguments)
      self.cached = cached
      self.adapter = adapter
    }

    public init(literal: SQL, adapter: (any RowAdapter)? = nil, cached: Bool = false) {
      self.literal = literal
      self.cached = cached
      self.adapter = adapter
    }

    public func sql(in db: Database) throws -> SQL {
      literal
    }

    public var sqlSubquery: SQLSubquery {
      .literal(literal)
    }

    public func makePreparedRequest(
      _ db: Database,
      forSingleResult singleResult: Bool = false
    ) throws -> PreparedRequest {
      let (sql, arguments) = try literal.build(db)
      let statement = try cached ? db.cachedStatement(sql: sql) : db.makeStatement(sql: sql)
      statement.arguments = arguments
      return PreparedRequest(statement: statement, adapter: adapter)
    }

    public func asRequest<T>(of type: T.Type) -> SQLRequest<T> {
      .init(literal: literal, adapter: adapter, cached: cached)
    }
  }

  extension SQLRequest where RowDecoder == Row {
    /// Creates a request of rows from raw SQL.
    public init(
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil,
      cached: Bool = false
    ) {
      self.init(literal: SQL(sql: sql, arguments: arguments), adapter: adapter, cached: cached)
    }

    /// Creates a request of rows from an SQL literal.
    public init(literal: SQL, adapter: (any RowAdapter)? = nil, cached: Bool = false) {
      self.literal = literal
      self.cached = cached
      self.adapter = adapter
    }
  }

  extension SQLRequest: ExpressibleByStringInterpolation {
    public typealias StringInterpolation = SQLInterpolation

    public init(stringLiteral value: String) {
      self.init(sql: value)
    }

    public init(stringInterpolation: SQLInterpolation) {
      self.init(literal: SQL(stringInterpolation: stringInterpolation))
    }
  }

  // MARK: - QueryInterfaceRequest

  /// A request built with the query interface.
  public struct QueryInterfaceRequest<RowDecoder>: Sendable {
    var relation: SQLRelation

    init(relation: SQLRelation) {
      self.relation = relation
    }

    init(table: String) {
      relation = .all(fromTable: table)
    }

    func with(_ update: (inout Self) throws -> Void) rethrows -> Self {
      var result = self
      try update(&result)
      return result
    }

    var table: String { relation.source.tableName }
  }

  extension QueryInterfaceRequest: FetchRequest {
    public var sqlSubquery: SQLSubquery {
      .relation(relation)
    }

    public func sql(in db: Database) throws -> SQL {
      let context = SQLGenerationContext(db)
      let sql = try SQLQueryGenerator(relation: relation).requestSQL(context)
      return SQL(sql: sql, arguments: context.arguments)
    }

    public func makePreparedRequest(
      _ db: Database,
      forSingleResult singleResult: Bool = false
    ) throws -> PreparedRequest {
      var prepared = try SQLQueryGenerator(relation: relation, forSingleResult: singleResult)
        .makePreparedRequest(db)
      let associations = relation.prefetchedAssociations
      if !associations.isEmpty {
        // Observe the tables of prefetched associations, even before any row is fetched.
        if !prepared.statement.databaseRegion.isEmpty {
          prepared.statement.databaseRegion = try prepared.statement.databaseRegion
            .union(relation.prefetchedRegion(db))
        }
        let relation = relation
        prepared.supplementaryFetch = { db, rows, willExecute in
          try prefetch(
            db,
            associations: associations,
            from: relation,
            into: rows,
            willExecute: willExecute
          )
        }
      }
      return prepared
    }

    public func fetchCount(_ db: Database) throws -> Int {
      try relation.fetchCount(db)
    }

  }

  extension QueryInterfaceRequest: TypedRequest {}

  extension QueryInterfaceRequest: SelectionRequest {
    public func selectWhenConnected(
      _ selection: @escaping @Sendable (Database) throws -> [any SQLSelectable]
    ) -> Self {
      with {
        $0.relation = $0.relation.selectWhenConnected { try selection($0).map(\.sqlSelection) }
      }
    }

    public func annotatedWhenConnected(
      with selection: @escaping @Sendable (Database) throws -> [any SQLSelectable]
    ) -> Self {
      with {
        $0.relation = $0.relation.annotatedWhenConnected { try selection($0).map(\.sqlSelection) }
      }
    }

    public func select<T>(_ selection: [any SQLSelectable], as type: T.Type = T.self)
      -> QueryInterfaceRequest<T>
    {
      select(selection).asRequest(of: T.self)
    }

    public func select<T>(_ selection: any SQLSelectable..., as type: T.Type = T.self)
      -> QueryInterfaceRequest<T>
    {
      select(selection, as: type)
    }

    public func select<T>(
      _ selection: (DatabaseComponents) throws -> any SQLSelectable,
      as type: T.Type = T.self
    ) rethrows -> QueryInterfaceRequest<T> where RowDecoder: TableRecord {
      try select([selection(RowDecoder.databaseComponents)], as: type)
    }

    public func select<T>(
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      as type: T.Type = T.self
    ) -> QueryInterfaceRequest<T> {
      select([SQL(sql: sql, arguments: arguments)], as: type)
    }

    public func select<T>(literal: SQL, as type: T.Type = T.self) -> QueryInterfaceRequest<T> {
      select([literal], as: type)
    }

    public func selectPrimaryKey<PrimaryKey>(as type: PrimaryKey.Type = PrimaryKey.self)
      -> QueryInterfaceRequest<PrimaryKey>
    {
      let table = self.table
      return
        selectWhenConnected { db in try db.primaryKey(table).columns.map { Column($0) } }
        .asRequest(of: PrimaryKey.self)
    }

    public func selectID() -> QueryInterfaceRequest<RowDecoder.ID>
    where RowDecoder: Identifiable {
      let table = self.table
      return selectWhenConnected { db in
        let key = try db.primaryKey(table)
        guard key.columns.count == 1 else {
          throw DatabaseError(
            resultCode: .SQLITE_MISUSE,
            message: "selectID requires a single-column primary key in the table \(table)"
          )
        }
        return [Column(key.columns[0])]
      }
      .asRequest(of: RowDecoder.ID.self)
    }

    func selecting(_ selection: [any SQLSelectable]) -> Self {
      select(selection)
    }
  }

  extension QueryInterfaceRequest: FilteredRequest {
    public func filterWhenConnected(
      _ predicate: @escaping @Sendable (Database) throws -> any SQLExpressible
    ) -> Self {
      with { $0.relation = $0.relation.filterWhenConnected { try predicate($0).sqlExpression } }
    }
  }

  extension QueryInterfaceRequest: OrderedRequest {
    public func orderWhenConnected(
      _ orderings: @escaping @Sendable (Database) throws -> [any SQLOrderingTerm]
    ) -> Self {
      with { $0.relation = $0.relation.orderWhenConnected { try orderings($0).map(\.sqlOrdering) } }
    }

    public func reversed() -> Self {
      with { $0.relation = $0.relation.reversed() }
    }

    public func unordered() -> Self {
      with { $0.relation = $0.relation.unordered() }
    }

    public func withStableOrder() -> Self {
      with { $0.relation = $0.relation.withStableOrder() }
    }

    func ordered(by terms: [any SQLOrderingTerm]) -> Self {
      order(terms)
    }
  }

  extension QueryInterfaceRequest: AggregatingRequest {
    public func groupWhenConnected(
      _ expressions: @escaping @Sendable (Database) throws -> [any SQLExpressible]
    ) -> Self {
      with {
        $0.relation = $0.relation.groupWhenConnected { try expressions($0).map(\.sqlExpression) }
      }
    }

    public func havingWhenConnected(
      _ predicate: @escaping @Sendable (Database) throws -> any SQLExpressible
    ) -> Self {
      with { $0.relation = $0.relation.havingWhenConnected { try predicate($0).sqlExpression } }
    }
  }

  extension QueryInterfaceRequest: TableRequest {
    public var databaseTableName: String {
      relation.source.tableName
    }

    public func _aliased(_ alias: TableAliasBase) -> Self {
      with { $0.relation = $0.relation.aliased(alias) }
    }
  }

  extension QueryInterfaceRequest: DerivableRequest {
    public func distinct() -> Self {
      with { $0.relation.isDistinct = true }
    }

    public func limit(_ limit: Int, offset: Int? = nil) -> Self {
      with { $0.relation.limit = SQLLimit(limit: limit, offset: offset) }
    }

    public func with<T>(_ cte: CommonTableExpression<T>) -> Self {
      with { $0.relation = $0.relation.appendingCTE(cte.tableName, cte.cte) }
    }
  }

  extension QueryInterfaceRequest {
    public func asRequest<T>(of type: T.Type) -> QueryInterfaceRequest<T> {
      QueryInterfaceRequest<T>(relation: relation)
    }
  }

  extension QueryInterfaceRequest where RowDecoder: TableRecord {
    public typealias DatabaseComponents = RowDecoder.DatabaseComponents
  }

  // MARK: - TableRecord

  /// A type that is associated with a database table.
  public protocol TableRecord {
    /// The columns of the table, used by the closure-based query interface.
    associatedtype Columns = Never

    /// The components available in query-interface closures such as `filter { $0.score > 0 }`.
    associatedtype DatabaseComponents = Columns.Type

    static var databaseTableName: String { get }

    static var databaseSelection: [any SQLSelectable] { get }

    static var databaseComponents: DatabaseComponents { get }
  }

  extension TableRecord where DatabaseComponents == Columns.Type {
    public static var databaseComponents: DatabaseComponents {
      Columns.self
    }
  }

  extension TableRecord {
    public static var databaseTableName: String {
      defaultDatabaseTableName(for: Self.self)
    }

    public static var databaseSelection: [any SQLSelectable] {
      [AllColumns()]
    }

    static var relationForAll: SQLRelation {
      let selection = databaseSelection.map(\.sqlSelection)
      return SQLRelation(
        source: SQLSource(tableName: databaseTableName, alias: nil),
        selection: Deferred(value: selection)
      )
    }
  }

  /// Derives a table name from a type name: `Player` -> `player`, `HTTPRequest` -> `httpRequest`.
  func defaultDatabaseTableName(for type: Any.Type) -> String {
    let typeName = String(
      String(describing: type).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    )
    let initial = typeName.prefix { $0.isUppercase }
    switch initial.count {
    case typeName.count:
      return initial.lowercased()
    case 0:
      return typeName
    case 1:
      return initial.lowercased() + typeName.dropFirst()
    default:
      return initial.dropLast().lowercased() + typeName.dropFirst(initial.count - 1)
    }
  }

  // MARK: - Table

  /// A database table, for building requests without a record type.
  public struct Table<RowDecoder>: Sendable {
    public var tableName: String

    public init(_ tableName: String) {
      self.tableName = tableName
    }

    var relationForAll: SQLRelation {
      .all(fromTable: tableName)
    }
  }

  extension Table where RowDecoder == Row {
    public init(_ tableName: String) {
      self.tableName = tableName
    }
  }

  extension Table where RowDecoder: TableRecord {
    public typealias DatabaseComponents = RowDecoder.DatabaseComponents
  }

  // MARK: - Fetching requests

  extension FetchRequest where RowDecoder == Row {
    public func fetchCursor(_ db: Database) throws -> RowCursor {
      try Row.fetchCursor(db, self)
    }
  }

  extension FetchableRecord {
    public static func fetchOne(_ db: Database, _ request: some FetchRequest) throws -> Self? {
      try Row.fetchOneRow(db, request).map(Self.init(row:))
    }

    public static func fetchAll(_ db: Database, _ request: some FetchRequest) throws -> [Self] {
      try Row.fetchAllRows(db, request).map(Self.init(row:))
    }
  }

  extension Row {
    public static func fetchOne(_ db: Database, _ request: some FetchRequest) throws -> Row? {
      try fetchOneRow(db, request)
    }

    public static func fetchAll(_ db: Database, _ request: some FetchRequest) throws -> [Row] {
      try fetchAllRows(db, request)
    }

    public static func fetchCursor(_ db: Database, _ request: some FetchRequest) throws -> RowCursor
    {
      let prepared = try request.makePreparedRequest(db, forSingleResult: false)
      guard prepared.supplementaryFetch == nil else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "Not implemented: fetchCursor with supplementary fetch"
        )
      }
      return try fetchCursor(prepared.statement, adapter: prepared.adapter)
    }

    /// Fetches owned rows, then the rows of prefetched associations.
    static func fetchAllRows(_ db: Database, _ request: some FetchRequest) throws -> [Row] {
      let prepared = try request.makePreparedRequest(db, forSingleResult: false)
      let rows = try Array(
        fetchCursor(prepared.statement, adapter: prepared.adapter).map { $0.copy() }
      )
      try prepared.supplementaryFetch?(db, rows, nil)
      return rows
    }

    /// Fetches one owned row, then the rows of prefetched associations.
    static func fetchOneRow(_ db: Database, _ request: some FetchRequest) throws -> Row? {
      let prepared = try request.makePreparedRequest(db, forSingleResult: true)
      guard let row = try fetchOne(prepared.statement, adapter: prepared.adapter) else {
        return nil
      }
      try prepared.supplementaryFetch?(db, [row], nil)
      return row
    }
  }
#endif
