#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public typealias ColumnAssignment = SQLAssignment
  public typealias SQLOrdering = SQLExpression

  func sqlFunction(
    _ name: String,
    _ arguments: [SQLExpression],
    filter: (any SQLExpressible)? = nil
  ) -> SQLExpression {
    var sql =
      SQL(sql: name + "(") + joined(arguments.map(\.literal), separator: ", ") + SQL(sql: ")")
    if let filter {
      sql = sql + SQL(sql: " FILTER (WHERE ") + filter.sqlExpression.literal + SQL(sql: ")")
    }
    return SQLExpression(sql)
  }

  public func abs(_ value: some SQLExpressible) -> SQLExpression {
    sqlFunction("ABS", [value.sqlExpression])
  }

  public func length(_ value: some SQLExpressible) -> SQLExpression {
    sqlFunction("LENGTH", [value.sqlExpression])
  }

  public func average(_ value: some SQLExpressible, filter: (any SQLExpressible)? = nil)
    -> SQLExpression
  {
    sqlFunction("AVG", [value.sqlExpression], filter: filter)
  }

  public func sum(_ value: some SQLExpressible, filter: (any SQLExpressible)? = nil)
    -> SQLExpression
  {
    sqlFunction("SUM", [value.sqlExpression], filter: filter)
  }

  public func total(_ value: some SQLExpressible, filter: (any SQLExpressible)? = nil)
    -> SQLExpression
  {
    sqlFunction("TOTAL", [value.sqlExpression], filter: filter)
  }

  public func ?? (lhs: some SQLExpressible, rhs: (any DatabaseValueConvertible)?) -> SQLExpression {
    sqlFunction("IFNULL", [lhs.sqlExpression, SQLExpression(value: rhs)])
  }

  public func + (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "+", rhs.sqlExpression)
  }

  public func - (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "-", rhs.sqlExpression)
  }

  public func * (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "*", rhs.sqlExpression)
  }

  public func / (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "/", rhs.sqlExpression)
  }

  public func < (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "<", rhs.sqlExpression)
  }

  public func <= (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, "<=", rhs.sqlExpression)
  }

  public func > (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, ">", rhs.sqlExpression)
  }

  public func >= (lhs: some SQLExpressible, rhs: some SQLExpressible) -> SQLExpression {
    binary(lhs.sqlExpression, ">=", rhs.sqlExpression)
  }

  extension SQL: SQLExpressible {
    public var sqlExpression: SQLExpression {
      SQLExpression(self)
    }
  }

  extension SQLExpressible {

    public var isEmpty: SQLExpression {
      length(self) == 0
    }

    public func collating(_ collation: String) -> SQLExpression {
      SQLExpression(sqlExpression.literal + SQL(sql: " COLLATE " + quoted(collation)))
    }
  }

  extension ColumnExpression {
    public func set(to value: some SQLExpressible) -> SQLAssignment {
      SQLAssignment(column: name, value: value.sqlExpression.literal)
    }
  }

  extension SQLExpression {
    public var ascNullsLast: SQLExpression {
      var result = Self(literal + SQL(sql: " ASC NULLS LAST"))
      result.orderingReversal = literal + SQL(sql: " DESC NULLS FIRST")
      return result
    }

    public var descNullsFirst: SQLExpression {
      var result = Self(literal + SQL(sql: " DESC NULLS FIRST"))
      result.orderingReversal = literal + SQL(sql: " ASC NULLS LAST")
      return result
    }
  }

  extension ColumnExpression {
    public var ascNullsLast: SQLExpression {
      sqlExpression.ascNullsLast
    }

    public var descNullsFirst: SQLExpression {
      sqlExpression.descNullsFirst
    }
  }

  extension ClosedRange where Bound: DatabaseValueConvertible {
    public func contains(_ expression: some SQLExpressible) -> SQLExpression {
      SQLExpression(
        SQL(sql: "(") + expression.sqlExpression.literal
          + SQL(sql: " BETWEEN ? AND ?)", arguments: [lowerBound, upperBound])
      )
    }
  }

  extension Range where Bound: DatabaseValueConvertible {
    public func contains(_ expression: some SQLExpressible) -> SQLExpression {
      (expression >= lowerBound) && (expression < upperBound)
    }
  }

  func reverseOrderings(_ terms: [any SQLOrderingTerm]) -> [SQL]? {
    var result: [SQL] = []
    for term in terms {
      if let expression = term as? SQLExpression {
        result.append(expression.orderingReversal ?? (expression.literal + SQL(sql: " DESC")))
      } else if let column = term as? any ColumnExpression {
        result.append(column.sqlExpression.desc.literal)
      } else {
        return nil
      }
    }
    return result
  }

  extension TableRecord {
    public static func reversed() -> QueryInterfaceRequest<Self> {
      all().reversed()
    }

    public static func unordered() -> QueryInterfaceRequest<Self> {
      all().unordered()
    }

    public static func order(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<Self>
    {
      all().order(sql: sql, arguments: arguments)
    }

    public static func select<T>(_ selections: any SQLSelectable..., as type: T.Type)
      -> QueryInterfaceRequest<T>
    {
      var result = all().asRequest(of: type)
      result.selections = selections.map(\.sqlSelection)
      return result
    }
  }

  extension Table where RowDecoder: Hashable {
    public func fetchSet(_ db: Database) throws -> Set<RowDecoder> {
      try all().fetchSet(db)
    }
  }
#endif
