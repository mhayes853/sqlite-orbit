#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - SelectionRequest

  /// A request that can define its selection.
  public protocol SelectionRequest {
    func selectWhenConnected(
      _ selection: @escaping @Sendable (Database) throws -> [any SQLSelectable]
    ) -> Self

    func annotatedWhenConnected(
      with selection: @escaping @Sendable (Database) throws -> [any SQLSelectable]
    ) -> Self
  }

  extension SelectionRequest {
    public func select(_ selection: [any SQLSelectable]) -> Self {
      let selection = selection.map(\.sqlSelection)
      return selectWhenConnected { _ in selection }
    }

    public func select(_ selection: any SQLSelectable...) -> Self {
      select(selection)
    }

    public func select(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      select([SQL(sql: sql, arguments: arguments)])
    }

    public func select(literal: SQL) -> Self {
      select([literal])
    }

    public func annotated(with selection: [any SQLSelectable]) -> Self {
      let selection = selection.map(\.sqlSelection)
      return annotatedWhenConnected { _ in selection }
    }

    public func annotated(with selection: any SQLSelectable...) -> Self {
      annotated(with: selection)
    }
  }

  extension SelectionRequest where Self: TypedRequest, Self.RowDecoder: TableRecord {
    public typealias DatabaseComponents = RowDecoder.DatabaseComponents

    public func select(
      _ selection: (RowDecoder.DatabaseComponents) throws -> any SQLSelectable
    ) rethrows -> Self {
      try select([selection(RowDecoder.databaseComponents)])
    }

    public func select(
      _ selection: (RowDecoder.DatabaseComponents) throws -> [any SQLSelectable]
    ) rethrows -> Self {
      try select(selection(RowDecoder.databaseComponents))
    }

    public func annotated(
      with selection: (RowDecoder.DatabaseComponents) throws -> any SQLSelectable
    ) rethrows -> Self {
      try annotated(with: [selection(RowDecoder.databaseComponents)])
    }

    public func annotated(
      with selection: (RowDecoder.DatabaseComponents) throws -> [any SQLSelectable]
    ) rethrows -> Self {
      try annotated(with: selection(RowDecoder.databaseComponents))
    }
  }

  // MARK: - FilteredRequest

  /// A request that can be filtered.
  public protocol FilteredRequest {
    func filterWhenConnected(
      _ predicate: @escaping @Sendable (Database) throws -> any SQLExpressible
    ) -> Self
  }

  extension FilteredRequest {
    public func filter(_ predicate: some SQLSpecificExpressible) -> Self {
      let predicate = predicate.sqlExpression
      return filterWhenConnected { _ in predicate }
    }

    public func filter(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      filter(SQL(sql: sql, arguments: arguments))
    }

    public func filter(literal: SQL) -> Self {
      filter(literal)
    }

    /// A request that fetches no row.
    public func none() -> Self {
      filterWhenConnected { _ in false }
    }

    /// The request itself.
    public func all() -> Self {
      self
    }
  }

  extension FilteredRequest where Self: TypedRequest, Self.RowDecoder: TableRecord {
    public typealias DatabaseComponents = RowDecoder.DatabaseComponents

    public func filter(
      _ predicate: (RowDecoder.DatabaseComponents) throws -> any SQLSpecificExpressible
    ) rethrows -> Self {
      try filter(predicate(RowDecoder.databaseComponents).sqlExpression)
    }
  }

  // MARK: - TableRequest

  /// A request that feeds from a database table.
  public protocol TableRequest {
    var databaseTableName: String { get }

    func _aliased(_ alias: TableAliasBase) -> Self
  }

  extension TableRequest where Self: TypedRequest {
    /// Gives the request's table an alias, for referring to it from other tables.
    public func aliased(_ alias: TableAlias<Void>) -> Self {
      _aliased(alias)
    }

    /// Gives the request's table an alias, for referring to it from other tables.
    public func aliased(_ alias: TableAlias<RowDecoder>) -> Self {
      _aliased(alias)
    }
  }

  extension Database {
    func filteringPrimaryKeyColumn(_ table: String) throws -> String {
      let key = try primaryKey(table)
      guard key.columns.count == 1 else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message:
            "Filtering by primary key requires a single-column primary key in the table \(table)"
        )
      }
      return key.columns[0]
    }

    /// The columns of a unique key contained in `columns`, in key order.
    func columnsForUniqueKey(_ columns: some Collection<String>, in table: String) throws
      -> [String]?
    {
      let wanted = Set(columns.map { $0.lowercased() })
      if wanted.isEmpty { return nil }
      if let key = try? primaryKey(table) {
        if wanted == ["rowid"], try tableHasRowID(table) { return ["rowid"] }
        if Set(key.columns.map { $0.lowercased() }).isSubset(of: wanted) { return key.columns }
      }
      if try tableExists(table),
        let index = try indexes(on: table)
          .first(where: {
            $0.isUnique && Set($0.columns.map { $0.lowercased() }).isSubset(of: wanted)
          })
      {
        return index.columns
      }
      return nil
    }
  }

  /// Encodes a primary key value with the record's date, data, and UUID strategies.
  func encodedKeyValue(
    _ value: any DatabaseValueConvertible,
    column: String,
    record: (any EncodableRecord.Type)?
  ) throws -> DatabaseValue {
    if let date = value as? Date {
      return encodeDatabaseDate(
        date,
        strategy: record?.databaseDateEncodingStrategy(for: column) ?? .deferredToDate
      )
    }
    if let data = value as? Data {
      return try encodeDatabaseData(
        data,
        strategy: record?.databaseDataEncodingStrategy(for: column) ?? .deferredToData
      )
    }
    if let uuid = value as? UUID {
      return encodeDatabaseUUID(
        uuid,
        strategy: record?.databaseUUIDEncodingStrategy(for: column) ?? .deferredToUUID
      )
    }
    return value.databaseValue
  }

  extension TableRequest where Self: FilteredRequest, Self: TypedRequest {
    /// Filters by primary key.
    public func filter(key: some DatabaseValueConvertible) -> Self {
      filter(primaryKeyValues: [key])
    }

    /// Filters by primary keys.
    public func filter<Keys>(keys: Keys) -> Self
    where Keys: Collection, Keys.Element: DatabaseValueConvertible {
      filter(primaryKeyValues: keys.map { $0 })
    }

    /// Filters by primary key, with a possibly nil key.
    @_disfavoredOverload
    public func filter(key: (any DatabaseValueConvertible)?) -> Self {
      filter(primaryKeyValues: [key])
    }

    /// Filters by primary keys.
    @_disfavoredOverload
    public func filter<S: Sequence>(keys: S) -> Self where S.Element: DatabaseValueConvertible {
      filter(primaryKeyValues: keys.map { $0 })
    }

    /// Filters by primary key, with a possibly nil key.
    @_disfavoredOverload
    public func filter(id: (any DatabaseValueConvertible)?) -> Self {
      filter(primaryKeyValues: [id])
    }

    /// Filters by primary keys.
    @_disfavoredOverload
    public func filter<S: Sequence>(ids: S) -> Self where S.Element: DatabaseValueConvertible {
      filter(primaryKeyValues: ids.map { $0 })
    }

    func filter(primaryKeyValues: [(any DatabaseValueConvertible)?]) -> Self {
      let values = primaryKeyValues.compactMap { value -> (any DatabaseValueConvertible)? in
        guard let value, !value.databaseValue.isNull else { return nil }
        return value
      }
      if values.isEmpty { return none() }
      let table = databaseTableName
      let record = UncheckedSendable(value: RowDecoder.self as? any EncodableRecord.Type)
      let boxed = UncheckedSendable(value: values)
      return filterWhenConnected { db in
        let column = try db.filteringPrimaryKeyColumn(table)
        let expressions = try boxed.value.map {
          try encodedKeyValue($0, column: column, record: record.value).sqlExpression
        }
        return SQLCollection.array(expressions).contains(Column(column).sqlExpression)
      }
    }

    /// Filters by a unique key.
    public func filter(key: [String: (any DatabaseValueConvertible)?]?) -> Self {
      guard let key else { return none() }
      return filter(keys: [key])
    }

    /// Filters by unique keys.
    public func filter(keys: [[String: (any DatabaseValueConvertible)?]]) -> Self {
      if keys.isEmpty { return none() }
      let keys = keys.map { $0.mapValues { $0?.databaseValue ?? .null } }
      let table = databaseTableName
      return filterWhenConnected { db in
        try keys.map { key -> SQLExpression in
          guard let columns = try db.columnsForUniqueKey(key.keys, in: table) else {
            let kind = (try? db.viewExists(table)) == true ? "database view" : "table"
            throw DatabaseError(
              resultCode: .SQLITE_MISUSE,
              message:
                "\(kind) \(table) has no unique key on column(s) \(key.keys.sorted().joined(separator: ", "))"
            )
          }
          let order = columns.map { $0.lowercased() }
          return
            key
            .sorted {
              (order.firstIndex(of: $0.key.lowercased()) ?? .max)
                < (order.firstIndex(of: $1.key.lowercased()) ?? .max)
            }
            .map { Column($0.key) == $0.value }
            .joined(operator: .and)
        }
        .joined(operator: .or)
      }
    }
  }

  extension TableRequest
  where
    Self: FilteredRequest, Self: TypedRequest, RowDecoder: Identifiable,
    RowDecoder.ID: DatabaseValueConvertible
  {
    /// Filters by identifier.
    public func filter(id: RowDecoder.ID) -> Self {
      filter(primaryKeyValues: [id])
    }

    /// Filters by identifiers.
    public func filter(ids: some Collection<RowDecoder.ID>) -> Self {
      filter(primaryKeyValues: ids.map { $0 })
    }
  }

  extension TableRequest where Self: OrderedRequest {
    /// Orders by primary key.
    public func orderByPrimaryKey() -> Self {
      let table = databaseTableName
      return orderWhenConnected { db in
        try db.primaryKey(table).columns.map { SQLExpression.column($0) }
      }
    }
  }

  extension TableRequest where Self: AggregatingRequest {
    /// Groups by primary key.
    public func groupByPrimaryKey() -> Self {
      let table = databaseTableName
      return groupWhenConnected { db in
        let key = try db.primaryKey(table)
        if let column = key.rowIDColumn { return [Column(column)] }
        if try db.tableHasRowID(table) { return [Column.rowID] }
        return key.columns.map { Column($0) }
      }
    }
  }

  // MARK: - AggregatingRequest

  /// A request that can be grouped.
  public protocol AggregatingRequest {
    func groupWhenConnected(
      _ expressions: @escaping @Sendable (Database) throws -> [any SQLExpressible]
    ) -> Self

    func havingWhenConnected(
      _ predicate: @escaping @Sendable (Database) throws -> any SQLExpressible
    ) -> Self
  }

  extension AggregatingRequest {
    public func group(_ expressions: [any SQLExpressible]) -> Self {
      let expressions = expressions.map(\.sqlExpression)
      return groupWhenConnected { _ in expressions }
    }

    public func group(_ expressions: any SQLExpressible...) -> Self {
      group(expressions)
    }

    public func group(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      group([SQL(sql: sql, arguments: arguments)])
    }

    public func group(literal: SQL) -> Self {
      group([literal])
    }

    public func having(_ predicate: some SQLExpressible) -> Self {
      let predicate = predicate.sqlExpression
      return havingWhenConnected { _ in predicate }
    }

    public func having(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      having(SQL(sql: sql, arguments: arguments))
    }

    public func having(literal: SQL) -> Self {
      having(literal)
    }
  }

  extension AggregatingRequest where Self: TypedRequest, Self.RowDecoder: TableRecord {
    public typealias DatabaseComponents = RowDecoder.DatabaseComponents

    public func group(
      _ expression: (RowDecoder.DatabaseComponents) throws -> any SQLExpressible
    ) rethrows -> Self {
      try group([expression(RowDecoder.databaseComponents)])
    }

    public func group(
      _ expressions: (RowDecoder.DatabaseComponents) throws -> [any SQLExpressible]
    ) rethrows -> Self {
      try group(expressions(RowDecoder.databaseComponents))
    }

    public func having(
      _ predicate: (RowDecoder.DatabaseComponents) throws -> any SQLExpressible
    ) rethrows -> Self {
      try having(predicate(RowDecoder.databaseComponents).sqlExpression)
    }
  }

  // MARK: - OrderedRequest

  /// A request that can be sorted.
  public protocol OrderedRequest {
    func orderWhenConnected(
      _ orderings: @escaping @Sendable (Database) throws -> [any SQLOrderingTerm]
    ) -> Self

    func reversed() -> Self

    func unordered() -> Self

    func withStableOrder() -> Self
  }

  extension OrderedRequest {
    public func order(_ orderings: any SQLOrderingTerm...) -> Self {
      order(orderings)
    }

    public func order(_ orderings: [any SQLOrderingTerm]) -> Self {
      let orderings = orderings.map(\.sqlOrdering)
      return orderWhenConnected { _ in orderings }
    }

    public func order(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      order([SQL(sql: sql, arguments: arguments)])
    }

    public func order(literal: SQL) -> Self {
      order([literal])
    }
  }

  extension OrderedRequest where Self: TypedRequest, Self.RowDecoder: TableRecord {
    public typealias DatabaseComponents = RowDecoder.DatabaseComponents

    public func order(
      _ ordering: (RowDecoder.DatabaseComponents) throws -> any SQLOrderingTerm
    ) rethrows -> Self {
      try order([ordering(RowDecoder.databaseComponents)])
    }

    public func order(
      _ orderings: (RowDecoder.DatabaseComponents) throws -> [any SQLOrderingTerm]
    ) rethrows -> Self {
      try order(orderings(RowDecoder.databaseComponents))
    }
  }

  // MARK: - DerivableRequest

  /// A request that can be refined with the full query interface.
  public protocol DerivableRequest<RowDecoder>: AggregatingRequest, FilteredRequest,
    JoinableRequest, OrderedRequest, SelectionRequest, TableRequest
  {
    func distinct() -> Self

    func with<T>(_ cte: CommonTableExpression<T>) -> Self
  }

  // MARK: - TableRecord requests

  extension TableRecord {
    /// A request for all records.
    public static func all() -> QueryInterfaceRequest<Self> {
      QueryInterfaceRequest(relation: relationForAll)
    }

    public static func none() -> QueryInterfaceRequest<Self> {
      all().none()
    }

    public static func select(_ selection: any SQLSelectable...) -> QueryInterfaceRequest<Self> {
      all().select(selection)
    }

    public static func select(_ selection: [any SQLSelectable]) -> QueryInterfaceRequest<Self> {
      all().select(selection)
    }

    public static func select(
      _ selection: (DatabaseComponents) throws -> any SQLSelectable
    ) rethrows -> QueryInterfaceRequest<Self> {
      try all().select([selection(databaseComponents)])
    }

    public static func select(
      _ selection: (DatabaseComponents) throws -> [any SQLSelectable]
    ) rethrows -> QueryInterfaceRequest<Self> {
      try all().select(selection(databaseComponents))
    }

    public static func select(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<Self>
    {
      all().select(sql: sql, arguments: arguments)
    }

    public static func select(literal: SQL) -> QueryInterfaceRequest<Self> {
      all().select(literal: literal)
    }

    public static func select<RowDecoder>(
      _ selection: [any SQLSelectable],
      as type: RowDecoder.Type = RowDecoder.self
    ) -> QueryInterfaceRequest<RowDecoder> {
      all().select(selection, as: type)
    }

    public static func select<RowDecoder>(
      _ selection: any SQLSelectable...,
      as type: RowDecoder.Type = RowDecoder.self
    ) -> QueryInterfaceRequest<RowDecoder> {
      all().select(selection, as: type)
    }

    public static func select<RowDecoder>(
      _ selection: (DatabaseComponents) throws -> any SQLSelectable,
      as type: RowDecoder.Type = RowDecoder.self
    ) rethrows -> QueryInterfaceRequest<RowDecoder> {
      try all().select([selection(databaseComponents)], as: type)
    }

    public static func select<RowDecoder>(
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      as type: RowDecoder.Type = RowDecoder.self
    ) -> QueryInterfaceRequest<RowDecoder> {
      all().select(sql: sql, arguments: arguments, as: type)
    }

    public static func select<RowDecoder>(
      literal: SQL,
      as type: RowDecoder.Type = RowDecoder.self
    ) -> QueryInterfaceRequest<RowDecoder> {
      all().select(literal: literal, as: type)
    }

    public static func selectPrimaryKey<PrimaryKey>(as type: PrimaryKey.Type = PrimaryKey.self)
      -> QueryInterfaceRequest<PrimaryKey>
    {
      all().selectPrimaryKey(as: type)
    }

    public static func annotated(with selection: [any SQLSelectable]) -> QueryInterfaceRequest<Self>
    {
      all().annotated(with: selection)
    }

    public static func annotated(with selection: any SQLSelectable...) -> QueryInterfaceRequest<
      Self
    > {
      all().annotated(with: selection)
    }

    public static func annotated(
      with selection: (DatabaseComponents) throws -> any SQLSelectable
    ) rethrows -> QueryInterfaceRequest<Self> {
      try all().annotated(with: [selection(databaseComponents)])
    }

    public static func annotated(
      with selection: (DatabaseComponents) throws -> [any SQLSelectable]
    ) rethrows -> QueryInterfaceRequest<Self> {
      try all().annotated(with: selection(databaseComponents))
    }

    public static func filter(_ predicate: some SQLSpecificExpressible) -> QueryInterfaceRequest<
      Self
    > {
      all().filter(predicate)
    }

    public static func filter(
      _ predicate: (DatabaseComponents) throws -> any SQLSpecificExpressible
    ) rethrows -> QueryInterfaceRequest<Self> {
      try all().filter(predicate(databaseComponents).sqlExpression)
    }

    public static func filter(key: some DatabaseValueConvertible) -> QueryInterfaceRequest<Self> {
      all().filter(key: key)
    }

    @_disfavoredOverload
    public static func filter(key: (any DatabaseValueConvertible)?) -> QueryInterfaceRequest<Self> {
      all().filter(key: key)
    }

    public static func filter<Keys>(keys: Keys) -> QueryInterfaceRequest<Self>
    where Keys: Collection, Keys.Element: DatabaseValueConvertible {
      all().filter(keys: keys)
    }

    @_disfavoredOverload
    public static func filter<S: Sequence>(keys: S) -> QueryInterfaceRequest<Self>
    where S.Element: DatabaseValueConvertible {
      all().filter(keys: keys)
    }

    @_disfavoredOverload
    public static func filter(id: (any DatabaseValueConvertible)?) -> QueryInterfaceRequest<Self> {
      all().filter(id: id)
    }

    @_disfavoredOverload
    public static func filter<S: Sequence>(ids: S) -> QueryInterfaceRequest<Self>
    where S.Element: DatabaseValueConvertible {
      all().filter(ids: ids)
    }

    public static func filter(key: [String: (any DatabaseValueConvertible)?]?)
      -> QueryInterfaceRequest<Self>
    {
      all().filter(key: key)
    }

    public static func filter(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<Self>
    {
      all().filter(sql: sql, arguments: arguments)
    }

    public static func filter(literal: SQL) -> QueryInterfaceRequest<Self> {
      all().filter(literal: literal)
    }

    public static func order(_ orderings: any SQLOrderingTerm...) -> QueryInterfaceRequest<Self> {
      all().order(orderings)
    }

    public static func order(_ orderings: [any SQLOrderingTerm]) -> QueryInterfaceRequest<Self> {
      all().order(orderings)
    }

    public static func order(
      _ ordering: (DatabaseComponents) throws -> any SQLOrderingTerm
    ) rethrows -> QueryInterfaceRequest<Self> {
      try all().order([ordering(databaseComponents)])
    }

    public static func order(
      _ orderings: (DatabaseComponents) throws -> [any SQLOrderingTerm]
    ) rethrows -> QueryInterfaceRequest<Self> {
      try all().order(orderings(databaseComponents))
    }

    public static func orderByPrimaryKey() -> QueryInterfaceRequest<Self> {
      all().orderByPrimaryKey()
    }

    public static func order(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<Self>
    {
      all().order(sql: sql, arguments: arguments)
    }

    public static func order(literal: SQL) -> QueryInterfaceRequest<Self> {
      all().order(literal: literal)
    }

    public static func reversed() -> QueryInterfaceRequest<Self> {
      all().reversed()
    }

    public static func unordered() -> QueryInterfaceRequest<Self> {
      all().unordered()
    }

    public static func limit(_ limit: Int, offset: Int? = nil) -> QueryInterfaceRequest<Self> {
      all().limit(limit, offset: offset)
    }

    public static func aliased(_ alias: TableAlias<Void>) -> QueryInterfaceRequest<Self> {
      all().aliased(alias)
    }

    public static func aliased(_ alias: TableAlias<Self>) -> QueryInterfaceRequest<Self> {
      all().aliased(alias)
    }

    public static func with<RowDecoder>(_ cte: CommonTableExpression<RowDecoder>)
      -> QueryInterfaceRequest<Self>
    {
      all().with(cte)
    }

    public static func fetchCount(_ db: Database) throws -> Int {
      try all().fetchCount(db)
    }
  }

  extension TableRecord where Self: Identifiable, ID: DatabaseValueConvertible {
    public static func filter(id: ID) -> QueryInterfaceRequest<Self> {
      all().filter(id: id)
    }

    public static func filter(ids: some Collection<ID>) -> QueryInterfaceRequest<Self> {
      all().filter(ids: ids)
    }

    public static func selectID() -> QueryInterfaceRequest<ID> {
      all().selectID()
    }
  }

  // MARK: - Table requests

  extension Table {
    public func all() -> QueryInterfaceRequest<RowDecoder> {
      QueryInterfaceRequest(relation: relationForAll)
    }

    public func none() -> QueryInterfaceRequest<RowDecoder> {
      all().none()
    }

    public func select(_ selection: [any SQLSelectable]) -> QueryInterfaceRequest<RowDecoder> {
      all().select(selection)
    }

    public func select(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<RowDecoder>
    {
      all().select(sql: sql, arguments: arguments)
    }

    public func select(literal: SQL) -> QueryInterfaceRequest<RowDecoder> {
      all().select(literal: literal)
    }

    public func select<T>(_ selection: [any SQLSelectable], as type: T.Type = T.self)
      -> QueryInterfaceRequest<T>
    {
      all().select(selection, as: type)
    }

    public func select<T>(
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      as type: T.Type = T.self
    ) -> QueryInterfaceRequest<T> {
      all().select(sql: sql, arguments: arguments, as: type)
    }

    public func select<T>(literal: SQL, as type: T.Type = T.self) -> QueryInterfaceRequest<T> {
      all().select(literal: literal, as: type)
    }

    public func selectPrimaryKey<PrimaryKey>(as type: PrimaryKey.Type = PrimaryKey.self)
      -> QueryInterfaceRequest<PrimaryKey>
    {
      all().selectPrimaryKey(as: type)
    }

    public func annotated(with selection: [any SQLSelectable]) -> QueryInterfaceRequest<RowDecoder>
    {
      all().annotated(with: selection)
    }

    public func annotated(with selection: any SQLSelectable...) -> QueryInterfaceRequest<RowDecoder>
    {
      all().annotated(with: selection)
    }

    public func filter(_ predicate: some SQLSpecificExpressible) -> QueryInterfaceRequest<
      RowDecoder
    > {
      all().filter(predicate)
    }

    public func filter(key: some DatabaseValueConvertible) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(key: key)
    }

    @_disfavoredOverload
    public func filter(key: (any DatabaseValueConvertible)?) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(key: key)
    }

    public func filter<Keys>(keys: Keys) -> QueryInterfaceRequest<RowDecoder>
    where Keys: Collection, Keys.Element: DatabaseValueConvertible {
      all().filter(keys: keys)
    }

    @_disfavoredOverload
    public func filter(id: (any DatabaseValueConvertible)?) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(id: id)
    }

    public func filter(key: [String: (any DatabaseValueConvertible)?]?) -> QueryInterfaceRequest<
      RowDecoder
    > {
      all().filter(key: key)
    }

    public func filter(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<RowDecoder>
    {
      all().filter(sql: sql, arguments: arguments)
    }

    public func filter(literal: SQL) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(literal: literal)
    }

    public func order(_ orderings: [any SQLOrderingTerm]) -> QueryInterfaceRequest<RowDecoder> {
      all().order(orderings)
    }

    public func orderByPrimaryKey() -> QueryInterfaceRequest<RowDecoder> {
      all().orderByPrimaryKey()
    }

    public func order(literal: SQL) -> QueryInterfaceRequest<RowDecoder> {
      all().order(literal: literal)
    }

    public func aliased(_ alias: TableAlias<Void>) -> QueryInterfaceRequest<RowDecoder> {
      all().aliased(alias)
    }

    public func aliased(_ alias: TableAlias<RowDecoder>) -> QueryInterfaceRequest<RowDecoder> {
      all().aliased(alias)
    }

    public func with<T>(_ cte: CommonTableExpression<T>) -> QueryInterfaceRequest<RowDecoder> {
      all().with(cte)
    }

    public func fetchCount(_ db: Database) throws -> Int {
      try all().fetchCount(db)
    }

    public func fetchAll(_ db: Database) throws -> [RowDecoder] {
      try all().fetchAll(db)
    }

    public func fetchOne(_ db: Database) throws -> RowDecoder? {
      try all().fetchOne(db)
    }

    /// Whether the table contains a row with the given primary key.
    public func exists(_ db: Database, key: some DatabaseValueConvertible) throws -> Bool {
      try !all().filter(key: key).isEmpty(db)
    }

    /// Whether the table contains a row with the given unique key.
    public func exists(_ db: Database, key: [String: (any DatabaseValueConvertible)?]) throws
      -> Bool
    {
      try !all().filter(key: key).isEmpty(db)
    }

    @discardableResult
    public func deleteAll<Keys>(_ db: Database, keys: Keys) throws -> Int
    where Keys: Collection, Keys.Element: DatabaseValueConvertible {
      if keys.isEmpty { return 0 }
      return try all().filter(keys: keys).deleteAll(db)
    }

    @discardableResult
    public func deleteOne(_ db: Database, key: some DatabaseValueConvertible) throws -> Bool {
      if key.databaseValue.isNull { return false }
      return try deleteAll(db, keys: [key]) > 0
    }

    @discardableResult
    public func deleteAll(_ db: Database, keys: [[String: (any DatabaseValueConvertible)?]]) throws
      -> Int
    {
      if keys.isEmpty { return 0 }
      return try all().filter(keys: keys).deleteAll(db)
    }

    @discardableResult
    public func deleteOne(_ db: Database, key: [String: (any DatabaseValueConvertible)?]) throws
      -> Bool
    {
      try deleteAll(db, keys: [key]) > 0
    }

    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment]
    ) throws -> Int {
      try all().updateAll(db, onConflict: conflict, assignments)
    }

    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: ColumnAssignment...
    ) throws -> Int {
      try all().updateAll(db, onConflict: conflict, assignments)
    }
  }

  extension Table where RowDecoder: TableRecord {
    public func select(
      _ selection: (DatabaseComponents) throws -> any SQLSelectable
    ) rethrows -> QueryInterfaceRequest<RowDecoder> {
      try all().select([selection(RowDecoder.databaseComponents)])
    }

    public func select(
      _ selection: (DatabaseComponents) throws -> [any SQLSelectable]
    ) rethrows -> QueryInterfaceRequest<RowDecoder> {
      try all().select(selection(RowDecoder.databaseComponents))
    }

    public func annotated(
      with selection: (DatabaseComponents) throws -> any SQLSelectable
    ) rethrows -> QueryInterfaceRequest<RowDecoder> {
      try all().annotated(with: [selection(RowDecoder.databaseComponents)])
    }

    public func annotated(
      with selection: (DatabaseComponents) throws -> [any SQLSelectable]
    ) rethrows -> QueryInterfaceRequest<RowDecoder> {
      try all().annotated(with: selection(RowDecoder.databaseComponents))
    }

    public func filter(
      _ predicate: (DatabaseComponents) throws -> any SQLSpecificExpressible
    ) rethrows -> QueryInterfaceRequest<RowDecoder> {
      try all().filter(predicate(RowDecoder.databaseComponents).sqlExpression)
    }

    public func order(
      _ ordering: (DatabaseComponents) throws -> any SQLOrderingTerm
    ) rethrows -> QueryInterfaceRequest<RowDecoder> {
      try all().order([ordering(RowDecoder.databaseComponents)])
    }

    public func order(
      _ orderings: (DatabaseComponents) throws -> [any SQLOrderingTerm]
    ) rethrows -> QueryInterfaceRequest<RowDecoder> {
      try all().order(orderings(RowDecoder.databaseComponents))
    }

    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignment: (DatabaseComponents) throws -> ColumnAssignment
    ) throws -> Int {
      try updateAll(db, onConflict: conflict, [assignment(RowDecoder.databaseComponents)])
    }

    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignments: (DatabaseComponents) throws -> [ColumnAssignment]
    ) throws -> Int {
      try updateAll(db, onConflict: conflict, assignments(RowDecoder.databaseComponents))
    }
  }

  extension Table where RowDecoder: Identifiable, RowDecoder.ID: DatabaseValueConvertible {
    public func filter(id: RowDecoder.ID) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(id: id)
    }

    public func filter(ids: some Collection<RowDecoder.ID>) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(ids: ids)
    }

    public func selectID() -> QueryInterfaceRequest<RowDecoder.ID> {
      all().selectID()
    }

    public func exists(_ db: Database, id: RowDecoder.ID) throws -> Bool {
      if id.databaseValue.isNull { return false }
      return try !all().filter(id: id).isEmpty(db)
    }

    @discardableResult
    public func deleteAll(_ db: Database, ids: some Collection<RowDecoder.ID>) throws -> Int {
      try deleteAll(db, keys: ids)
    }

    @discardableResult
    public func deleteOne(_ db: Database, id: RowDecoder.ID) throws -> Bool {
      try deleteOne(db, key: id)
    }
  }

  extension Table where RowDecoder: Hashable {
    public func fetchSet(_ db: Database) throws -> Set<RowDecoder> {
      try all().fetchSet(db)
    }
  }
#endif

#if canImport(Foundation) && canImport(Dispatch)
  extension TableRecord {
    @discardableResult
    @_disfavoredOverload
    public static func deleteOne(_ db: Database, id: (any DatabaseValueConvertible)?) throws
      -> Bool
    {
      guard let id, !id.databaseValue.isNull else { return false }
      return try all().filter(id: id).deleteAll(db) > 0
    }

    @_disfavoredOverload
    public static func exists(_ db: Database, id: (any DatabaseValueConvertible)?) throws -> Bool {
      guard let id, !id.databaseValue.isNull else { return false }
      return try !all().filter(id: id).isEmpty(db)
    }
  }

  extension TableRecord where Self: Identifiable, ID: DatabaseValueConvertible {
    @discardableResult
    public static func deleteOne(_ db: Database, id: ID) throws -> Bool {
      if id.databaseValue.isNull { return false }
      return try all().filter(id: id).deleteAll(db) > 0
    }

    public static func exists(_ db: Database, id: ID) throws -> Bool {
      if id.databaseValue.isNull { return false }
      return try !all().filter(id: id).isEmpty(db)
    }
  }
#endif
