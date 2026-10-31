#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// The definition of a common table expression.
  struct SQLCTE: Sendable {
    var tableName: String
    var columns: [String]?
    var subquery: SQLSubquery
    var isRecursive: Bool

    func columnNames(_ db: Database) throws -> [String] {
      if let columns { return columns }
      return try wrappingErrors { try subquery.columnNames(db) }
    }

    func columnCount(_ db: Database) throws -> Int {
      if let columns { return columns.count }
      return try wrappingErrors { try subquery.columnCount(db) }
    }

    private func wrappingErrors<T>(_ body: () throws -> T) throws -> T {
      do {
        return try body()
      } catch let error as DatabaseError where error.resultCode == .SQLITE_ERROR {
        let message = [
          [
            "Can't compute the number of columns in the \(String(reflecting: tableName)) common table expression",
            error.message
          ]
          .compactMap { $0 }.joined(separator: ": "),
          "Check the syntax of the SQL definition, or provide the explicit list of selected columns with the `columns` parameter in the CommonTableExpression initializer."
        ]
        .joined(separator: ". ")
        throw DatabaseError(resultCode: error.resultCode, message: message)
      }
    }
  }

  /// A common table expression, usable in requests with `with(_:)`.
  public struct CommonTableExpression<RowDecoder>: Sendable {
    var cte: SQLCTE

    /// The name of the common table expression.
    public var tableName: String { cte.tableName }

    private init(
      recursive: Bool,
      named tableName: String,
      columns: [String]?,
      subquery: SQLSubquery
    ) {
      cte = SQLCTE(
        tableName: tableName,
        columns: columns,
        subquery: subquery,
        isRecursive: recursive
      )
    }

    /// Creates a common table expression from a request.
    public init(
      recursive: Bool = false,
      named tableName: String,
      columns: [String]? = nil,
      request: some SQLSubqueryable
    ) {
      self.init(
        recursive: recursive,
        named: tableName,
        columns: columns,
        subquery: request.sqlSubquery
      )
    }

    /// Creates a common table expression from raw SQL.
    public init(
      recursive: Bool = false,
      named tableName: String,
      columns: [String]? = nil,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) {
      self.init(
        recursive: recursive,
        named: tableName,
        columns: columns,
        subquery: .literal(SQL(sql: sql, arguments: arguments))
      )
    }

    /// Creates a common table expression from an SQL literal.
    public init(
      recursive: Bool = false,
      named tableName: String,
      columns: [String]? = nil,
      literal: SQL
    ) {
      self.init(
        recursive: recursive,
        named: tableName,
        columns: columns,
        subquery: .literal(literal)
      )
    }

    var relationForAll: SQLRelation {
      .all(fromTable: tableName)
    }

    /// A request for all rows of the common table expression.
    public func all() -> QueryInterfaceRequest<RowDecoder> {
      QueryInterfaceRequest(relation: relationForAll)
    }

    /// An expression that tests whether the common table expression contains a value.
    public func contains(_ element: some SQLExpressible) -> SQLExpression {
      SQLCollection.table(tableName).contains(element.sqlExpression)
    }
  }

  extension CommonTableExpression where RowDecoder == Row {
    /// Creates a common table expression of rows from a request.
    public init(
      recursive: Bool = false,
      named tableName: String,
      columns: [String]? = nil,
      request: some SQLSubqueryable
    ) {
      self.init(
        recursive: recursive,
        named: tableName,
        columns: columns,
        subquery: request.sqlSubquery
      )
    }

    /// Creates a common table expression of rows from raw SQL.
    public init(
      recursive: Bool = false,
      named tableName: String,
      columns: [String]? = nil,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) {
      self.init(
        recursive: recursive,
        named: tableName,
        columns: columns,
        subquery: .literal(SQL(sql: sql, arguments: arguments))
      )
    }

    /// Creates a common table expression of rows from an SQL literal.
    public init(
      recursive: Bool = false,
      named tableName: String,
      columns: [String]? = nil,
      literal: SQL
    ) {
      self.init(
        recursive: recursive,
        named: tableName,
        columns: columns,
        subquery: .literal(literal)
      )
    }
  }

  extension SQLInterpolation {
    /// Appends the name of a common table expression.
    public mutating func appendInterpolation(_ cte: CommonTableExpression<some Any>) {
      appendLiteral(quoted(cte.tableName))
    }

    /// Appends the definition of a common table expression: `name(columns) AS (subquery)`.
    public mutating func appendInterpolation(definitionFor cte: CommonTableExpression<some Any>) {
      appendLiteral(quoted(cte.tableName))
      if let columns = cte.cte.columns, !columns.isEmpty {
        appendLiteral("(" + columns.map(quoted).joined(separator: ", ") + ")")
      }
      appendLiteral(" AS (")
      elements.append(.subquery(cte.cte.subquery))
      appendLiteral(")")
    }
  }
#endif
