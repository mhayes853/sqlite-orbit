#if StructuredQueries
  public import StructuredQueriesSQLite

  /// A reusable statement request created by `allRowsRequest()`, `firstRowRequest()`, or
  /// `requiredFirstRowRequest()`.
  ///
  /// Requests compare their SQL, bindings, fetch mode, and decoding type. Read one with `fetch`,
  /// create its observation with `observation()`, or pass it to `Fetch`.
  public struct OrbitStatementRequest<Value: Sendable>: OrbitFetchKeyRequest {
    /// The query and bindings this request reads.
    public let sql: SQL
    private let mode: Mode
    private let decodingType: ObjectIdentifier
    private let read: @Sendable (borrowing SQLiteReadTransaction) throws -> Value

    fileprivate enum Mode: Hashable { case allRows, firstRow, flattenedFirstRow, requiredFirstRow }

    fileprivate init<Decoded>(
      sql: SQL,
      mode: Mode,
      decoding: Decoded.Type,
      read: @escaping @Sendable (borrowing SQLiteReadTransaction) throws -> Value
    ) {
      self.sql = sql
      self.mode = mode
      self.decodingType = ObjectIdentifier(decoding)
      self.read = read
    }

    /// Reads the statement's value in a transaction.
    public func fetch(_ transaction: borrowing SQLiteReadTransaction) throws -> Value {
      try read(transaction)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.sql == rhs.sql && lhs.mode == rhs.mode && lhs.decodingType == rhs.decodingType
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(sql)
      hasher.combine(mode)
      hasher.combine(decodingType)
    }
  }

  extension Statement where QueryValue: QueryRepresentable, QueryValue.QueryOutput: Sendable {
    /// A reusable request for every result row, preserving the statement's order and bindings.
    public func allRowsRequest() -> OrbitStatementRequest<[QueryValue.QueryOutput]> {
      let sql = SQL(fragment: query)
      return OrbitStatementRequest(sql: sql, mode: .allRows, decoding: QueryValue.self) {
        try $0.fetchAll(sql) { try $0.decode(QueryValue.self) }
      }
    }

    /// A reusable request for the first result row, or `nil` when there is none.
    public func firstRowRequest() -> OrbitStatementRequest<QueryValue.QueryOutput?> {
      let sql = SQL(fragment: query)
      return OrbitStatementRequest(sql: sql, mode: .firstRow, decoding: QueryValue.self) {
        try $0.fetchOne(sql) { try $0.decode(QueryValue.self) }
      }
    }

    /// A reusable request for the first row, throwing `OrbitDatabaseRecordNotFoundError` if absent.
    public func requiredFirstRowRequest() -> OrbitStatementRequest<QueryValue.QueryOutput> {
      let sql = SQL(fragment: query)
      return OrbitStatementRequest(sql: sql, mode: .requiredFirstRow, decoding: QueryValue.self) {
        guard let value = try $0.fetchOne(sql, { try $0.decode(QueryValue.self) }) else {
          throw OrbitDatabaseRecordNotFoundError()
        }
        return value
      }
    }
  }

  extension Statement
  where
    QueryValue: QueryRepresentable & _OptionalProtocol,
    QueryValue.QueryOutput: _OptionalProtocol & Sendable
  {
    /// A first-row request that treats an absent row and a decoded null as the same optional value.
    public func firstRowRequest() -> OrbitStatementRequest<QueryValue.QueryOutput> {
      let sql = SQL(fragment: query)
      return OrbitStatementRequest(sql: sql, mode: .flattenedFirstRow, decoding: QueryValue.self) {
        try $0.fetchOne(sql) { try $0.decode(QueryValue.self) } ?? ._none
      }
    }
  }

  extension SelectStatement where QueryValue == (), Joins == (), From.QueryOutput: Sendable {
    /// A reusable request for every row of the selected table.
    public func allRowsRequest() -> OrbitStatementRequest<[From.QueryOutput]> {
      let statement: Select<From, From, ()> = selectStar()
      return statement.allRowsRequest()
    }

    /// A reusable request for the first selected table row, or `nil` when there is none.
    public func firstRowRequest() -> OrbitStatementRequest<From.QueryOutput?> {
      let statement: Select<From, From, ()> = selectStar()
      return statement.firstRowRequest()
    }

    /// A reusable request for the first table row, throwing when the result is empty.
    public func requiredFirstRowRequest() -> OrbitStatementRequest<From.QueryOutput> {
      let statement: Select<From, From, ()> = selectStar()
      return statement.requiredFirstRowRequest()
    }
  }

  extension Statement {
    /// A reusable request for every row of a tuple projection.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @_disfavoredOverload
    public func allRowsRequest<each Element: QueryRepresentable>()
      -> OrbitStatementRequest<[(repeat (each Element).QueryOutput)]>
    where QueryValue == (repeat each Element), repeat (each Element).QueryOutput: Sendable {
      let sql = SQL(fragment: query)
      return OrbitStatementRequest(sql: sql, mode: .allRows, decoding: (repeat each Element).self) {
        try $0.fetchAll(sql) { try $0.decode((repeat each Element).self) }
      }
    }

    /// A reusable request for the first tuple row, or `nil` when there is none.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @_disfavoredOverload
    public func firstRowRequest<each Element: QueryRepresentable>()
      -> OrbitStatementRequest<(repeat (each Element).QueryOutput)?>
    where QueryValue == (repeat each Element), repeat (each Element).QueryOutput: Sendable {
      let sql = SQL(fragment: query)
      return OrbitStatementRequest(sql: sql, mode: .firstRow, decoding: (repeat each Element).self)
      {
        try $0.fetchOne(sql) { try $0.decode((repeat each Element).self) }
      }
    }

    /// A reusable request for the first tuple row, throwing when the result is empty.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @_disfavoredOverload
    public func requiredFirstRowRequest<each Element: QueryRepresentable>()
      -> OrbitStatementRequest<(repeat (each Element).QueryOutput)>
    where QueryValue == (repeat each Element), repeat (each Element).QueryOutput: Sendable {
      let sql = SQL(fragment: query)
      return OrbitStatementRequest(
        sql: sql,
        mode: .requiredFirstRow,
        decoding: (repeat each Element).self
      ) {
        guard let value = try $0.fetchOne(sql, { try $0.decode((repeat each Element).self) }) else {
          throw OrbitDatabaseRecordNotFoundError()
        }
        return value
      }
    }
  }
#endif
