#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public typealias RecordCursor<Record> = AnyCursor<Record>
  public typealias DatabaseValueCursor<Value> = AnyCursor<Value>

  extension DatabaseValueConvertible {
    public static func fetchCursor(_ db: Database, _ literal: SQL) throws -> AnyCursor<Self> {
      try fetchCursor(db, sql: literal.sql, arguments: literal.arguments)
    }

    public static func fetchCursor(_ db: Database, _ request: some FetchRequest) throws
      -> AnyCursor<Self>
    {
      try Row.fetchCursor(db, request).map { try $0.decode(Self.self, at: 0) }
    }

    public static func fetchAll(_ db: Database, _ request: some FetchRequest) throws -> [Self] {
      try Array(fetchCursor(db, request))
    }

    public static func fetchOne(_ db: Database, _ request: some FetchRequest) throws -> Self? {
      let prepared = try request.makePreparedRequest(db, forSingleResult: true)
      return try fetchOne(prepared.statement, adapter: prepared.adapter)
    }
  }

  extension DatabaseValueConvertible where Self: Hashable {
    public static func fetchSet(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> Set<Self> {
      Set(try fetchAll(db, sql: sql, arguments: arguments, adapter: adapter))
    }

    public static func fetchSet(_ db: Database, _ literal: SQL) throws -> Set<Self> {
      Set(try fetchAll(db, literal))
    }

    public static func fetchSet(_ db: Database, _ request: some FetchRequest) throws -> Set<Self> {
      Set(try fetchAll(db, request))
    }

    public static func fetchSet(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> Set<Self>
    {
      Set(try fetchAll(statement, arguments: arguments, adapter: adapter))
    }
  }

  extension FetchableRecord {
    public static func fetchCursor(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    )
      throws -> AnyCursor<Self>
    {
      try Row.fetchCursor(statement, arguments: arguments, adapter: adapter).map(Self.init(row:))
    }

    public static func fetchAll(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> [Self]
    {
      try Array(fetchCursor(statement, arguments: arguments, adapter: adapter))
    }

    public static func fetchOne(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> Self?
    {
      try Row.fetchOne(statement, arguments: arguments, adapter: adapter).map(Self.init(row:))
    }

    public static func fetchCursor(_ db: Database, _ request: some FetchRequest) throws
      -> AnyCursor<Self>
    {
      try Row.fetchCursor(db, request).map(Self.init(row:))
    }

    public static func fetchCursor(_ db: Database, _ literal: SQL) throws -> AnyCursor<Self> {
      try fetchCursor(db, sql: literal.sql, arguments: literal.arguments)
    }
  }

  extension FetchableRecord where Self: Hashable {
    public static func fetchSet(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> Set<Self> {
      Set(try fetchAll(db, sql: sql, arguments: arguments, adapter: adapter))
    }

    public static func fetchSet(_ db: Database, _ literal: SQL) throws -> Set<Self> {
      Set(try fetchAll(db, literal))
    }

    public static func fetchSet(_ db: Database, _ request: some FetchRequest) throws -> Set<Self> {
      Set(try fetchAll(db, request))
    }

    public static func fetchSet(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> Set<Self>
    {
      Set(try fetchAll(statement, arguments: arguments, adapter: adapter))
    }
  }

  extension Row {
    public static func fetchCursor(_ db: Database, _ literal: SQL) throws -> RowCursor {
      try fetchCursor(db, sql: literal.sql, arguments: literal.arguments)
    }

    public static func fetchSet(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> Set<Row> {
      Set(try fetchAll(db, sql: sql, arguments: arguments, adapter: adapter))
    }

    public static func fetchSet(_ db: Database, _ literal: SQL) throws -> Set<Row> {
      Set(try fetchAll(db, literal))
    }

    public static func fetchSet(_ db: Database, _ request: some FetchRequest) throws -> Set<Row> {
      Set(try fetchAll(db, request))
    }

    public static func fetchSet(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> Set<Row>
    {
      Set(try fetchAll(statement, arguments: arguments, adapter: adapter))
    }
  }

  extension FetchRequest where RowDecoder: Hashable {
    public func fetchSet(_ db: Database) throws -> Set<RowDecoder> {
      Set(try fetchAll(db))
    }
  }

  extension FetchRequest {
    public func isEmpty(_ db: Database) throws -> Bool {
      let sql = try sql(in: db)
      return try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(\(sql.sql))", arguments: sql.arguments)!
    }
  }

  extension FetchableRecord where Self: TableRecord {
    public static func find(_ db: Database, key: (any DatabaseValueConvertible)?) throws -> Self {
      guard let record = try fetchOne(db, key: key) else {
        let primaryKey = try db.primaryKey(databaseTableName)
        guard primaryKey.columns.count == 1 else {
          throw DatabaseError(message: "a scalar key requires a single-column primary key")
        }
        throw RecordError.recordNotFound(
          databaseTableName: databaseTableName,
          key: [primaryKey.columns[0]: key?.databaseValue ?? .null]
        )
      }
      return record
    }

    public static func find(_ db: Database, key: [String: (any DatabaseValueConvertible)?]) throws
      -> Self
    {
      guard let record = try fetchOne(db, key: key) else {
        throw RecordError.recordNotFound(
          databaseTableName: databaseTableName,
          key: key.mapValues { $0?.databaseValue ?? .null }
        )
      }
      return record
    }

    public static func fetchCursor(_ db: Database, key: (any DatabaseValueConvertible)?) throws
      -> AnyCursor<Self>
    {
      try all().filter(key: key).fetchCursor(db)
    }

    public static func fetchCursor<S: Sequence>(_ db: Database, keys: S) throws -> AnyCursor<Self>
    where S.Element: DatabaseValueConvertible {
      try all().filter(keys: keys).fetchCursor(db)
    }

    public static func fetchAll(_ db: Database, keys: [[String: (any DatabaseValueConvertible)?]])
      throws -> [Self]
    {
      try all().filter(keys: keys).fetchAll(db)
    }

    public static func fetchCursor(
      _ db: Database,
      keys: [[String: (any DatabaseValueConvertible)?]]
    ) throws -> AnyCursor<Self> {
      try all().filter(keys: keys).fetchCursor(db)
    }
  }

  extension FetchableRecord where Self: TableRecord & Hashable {
    public static func fetchSet(_ db: Database) throws -> Set<Self> {
      try all().fetchSet(db)
    }

    public static func fetchSet<S: Sequence>(_ db: Database, keys: S) throws -> Set<Self>
    where S.Element: DatabaseValueConvertible {
      Set(try fetchAll(db, keys: keys))
    }

    public static func fetchSet<S: Sequence>(_ db: Database, ids: S) throws -> Set<Self>
    where S.Element: DatabaseValueConvertible {
      Set(try fetchAll(db, ids: ids))
    }

    public static func fetchSet(_ db: Database, keys: [[String: (any DatabaseValueConvertible)?]])
      throws -> Set<Self>
    {
      Set(try fetchAll(db, keys: keys))
    }
  }

  extension TableRecord {
    public static func filter(keys: [[String: (any DatabaseValueConvertible)?]])
      -> QueryInterfaceRequest<Self>
    {
      all().filter(keys: keys)
    }

    public static func exists(_ db: Database, key: (any DatabaseValueConvertible)?) throws -> Bool {
      try !all().filter(key: key).isEmpty(db)
    }

    public static func exists(_ db: Database, key: [String: (any DatabaseValueConvertible)?]) throws
      -> Bool
    {
      try !all().filter(key: key).isEmpty(db)
    }

    @discardableResult
    public static func deleteOne(_ db: Database, key: (any DatabaseValueConvertible)?) throws
      -> Bool
    {
      try all().filter(key: key).deleteAll(db) > 0
    }

    @discardableResult
    public static func deleteOne(_ db: Database, key: [String: (any DatabaseValueConvertible)?])
      throws -> Bool
    {
      try all().filter(key: key).deleteAll(db) > 0
    }

    @discardableResult
    public static func deleteAll<S: Sequence>(_ db: Database, keys: S) throws -> Int
    where S.Element: DatabaseValueConvertible {
      try all().filter(keys: keys).deleteAll(db)
    }

    @discardableResult
    public static func deleteAll<S: Sequence>(_ db: Database, ids: S) throws -> Int
    where S.Element: DatabaseValueConvertible {
      try all().filter(ids: ids).deleteAll(db)
    }

    @discardableResult
    public static func deleteAll(_ db: Database, keys: [[String: (any DatabaseValueConvertible)?]])
      throws -> Int
    {
      try all().filter(keys: keys).deleteAll(db)
    }
  }

  extension FetchableRecord where Self: TableRecord {
    public static func fetchCursor<S: Sequence>(_ db: Database, ids: S) throws -> AnyCursor<Self>
    where S.Element: DatabaseValueConvertible {
      try all().filter(ids: ids).fetchCursor(db)
    }
  }

  extension Table {
    public func fetchCursor(_ db: Database) throws -> AnyCursor<RowDecoder> {
      try all().fetchCursor(db)
    }

    public func filter<S: Sequence>(keys: S) -> QueryInterfaceRequest<RowDecoder>
    where S.Element: DatabaseValueConvertible {
      all().filter(keys: keys)
    }

    public func filter<S: Sequence>(ids: S) -> QueryInterfaceRequest<RowDecoder>
    where S.Element: DatabaseValueConvertible {
      all().filter(ids: ids)
    }

    public func filter(key: [String: (any DatabaseValueConvertible)?]) -> QueryInterfaceRequest<
      RowDecoder
    > {
      all().filter(key: key)
    }

    public func filter(keys: [[String: (any DatabaseValueConvertible)?]]) -> QueryInterfaceRequest<
      RowDecoder
    > {
      all().filter(keys: keys)
    }

    public func order(_ terms: any SQLOrderingTerm...) -> QueryInterfaceRequest<RowDecoder> {
      all().ordered(by: terms)
    }

    public func order(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<RowDecoder>
    {
      all().order(sql: sql, arguments: arguments)
    }

    public func select(_ selections: any SQLSelectable...) -> QueryInterfaceRequest<RowDecoder> {
      all().selecting(selections)
    }

    public func select<T>(_ selections: any SQLSelectable..., as type: T.Type)
      -> QueryInterfaceRequest<T>
    {
      all().asRequest(of: type).selecting(selections)
    }

    public func limit(_ count: Int, offset: Int? = nil) -> QueryInterfaceRequest<RowDecoder> {
      all().limit(count, offset: offset)
    }

    @discardableResult
    public func deleteAll(_ db: Database) throws -> Int {
      try all().deleteAll(db)
    }
  }

  extension Table where RowDecoder == Row {
    public func fetchCursor(_ db: Database) throws -> RowCursor {
      try all().fetchCursor(db)
    }
  }
#endif
