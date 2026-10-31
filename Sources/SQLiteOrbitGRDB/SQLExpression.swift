#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - Protocols

  /// A type that can be used as an SQL expression.
  public protocol SQLExpressible {
    var sqlExpression: SQLExpression { get }
  }

  /// A type that can be selected in a query.
  public protocol SQLSelectable {
    var sqlSelection: SQLSelection { get }
  }

  /// A type that can be used to sort query results.
  public protocol SQLOrderingTerm {
    var sqlOrdering: SQLOrdering { get }
  }

  /// An SQL expression rather than an ordinary Swift value.
  ///
  /// Only query-interface types adopt this protocol, so that operators and functions defined
  /// on it do not overload standard Swift operators.
  public protocol SQLSpecificExpressible: SQLExpressible, SQLSelectable, SQLOrderingTerm {}

  extension SQLSpecificExpressible {
    public var sqlSelection: SQLSelection { .expression(sqlExpression) }
    public var sqlOrdering: SQLOrdering { .expression(sqlExpression) }
  }

  extension SQLExpressible where Self == Column {
    /// The hidden rowID column.
    public static var rowID: Self { Column.rowID }
  }

  /// A column of a database table.
  public protocol ColumnExpression: SQLSpecificExpressible {
    var name: String { get }
  }

  extension ColumnExpression {
    public var sqlExpression: SQLExpression { .column(name) }

    /// The column name, unqualified even when the request uses table aliases.
    public var detached: SQLExpression {
      SQL(sql: quoted(name)).sqlExpression
    }
  }

  extension ColumnExpression where Self == Column {
    public static var rowID: Self { Column.rowID }
  }

  extension ColumnExpression where Self: RawRepresentable, RawValue == String {
    public var name: String { rawValue }
  }

  /// A column of a database table.
  public struct Column: ColumnExpression, Sendable {
    /// The hidden rowID column.
    public static let rowID = Column("rowid")

    public var name: String

    public init(_ name: String) {
      self.name = name
    }

    public init(_ codingKey: some CodingKey) {
      name = codingKey.stringValue
    }
  }

  // MARK: - SQLExpression

  /// An SQL expression.
  public struct SQLExpression: Sendable {
    indirect enum Node: Sendable {
      case column(String)
      case qualifiedColumn(String, TableAliasBase)
      case value(DatabaseValue)
      case row([SQLExpression])
      case subquery(SQLSubquery)
      case literal(SQL)
      case cast(SQLExpression, String)
      case between(SQLExpression, SQLExpression, SQLExpression, negated: Bool)
      case binary(String, SQLExpression, SQLExpression)
      case like(SQLExpression, SQLExpression, escape: SQLExpression?, negated: Bool)
      case associative(AssociativeBinaryOperator, [SQLExpression])
      case exists(SQLSubquery, negated: Bool)
      case `in`(SQLExpression, SQLCollection, negated: Bool)
      case unary(String, SQLExpression)
      case compare(ComparisonOperator, SQLExpression, SQLExpression)
      case tableMatch(TableAliasBase, SQLExpression)
      case not(SQLExpression)
      case collated(SQLExpression, String)
      case countAll
      case function(String, [SQLExpression], isPure: Bool)
      case aggregate(AggregateInvocation)
      case isEmpty(SQLExpression, negated: Bool)
      case fastPrimaryKey
      case qualifiedFastPrimaryKey(TableAliasBase)
      case qualifiedExists(TableAliasBase, negated: Bool)
    }

    struct AggregateInvocation: Sendable {
      var name: String
      var arguments: [SQLExpression]
      var isDistinct = false
      var ordering: SQLOrdering?
      var filter: SQLExpression?
    }

    enum ComparisonOperator: String, Sendable {
      case equal = "="
      case notEqual = "<>"
      case `is` = "IS"
      case isNot = "IS NOT"

      var negated: ComparisonOperator {
        switch self {
        case .equal: return .notEqual
        case .notEqual: return .equal
        case .is: return .isNot
        case .isNot: return .is
        }
      }
    }

    enum BooleanTest {
      case `true`, `false`, falsey
    }

    /// An operator that joins several expressions, such as `AND` or `+`.
    public struct AssociativeBinaryOperator: Hashable, Sendable {
      let sql: String
      let neutralValue: DatabaseValue
      let isStrictlyAssociative: Bool
      let isBijective: Bool

      public static let add = Self(sql: "+", neutralValue: 0.databaseValue, strict: false)
      public static let multiply = Self(sql: "*", neutralValue: 1.databaseValue, strict: false)
      public static let and = Self(sql: "AND", neutralValue: true.databaseValue, strict: true)
      public static let or = Self(sql: "OR", neutralValue: false.databaseValue, strict: true)
      public static let concat = Self(
        sql: "||",
        neutralValue: "".databaseValue,
        strict: true,
        bijective: true
      )
      public static let bitwiseAnd = Self(
        sql: "&",
        neutralValue: (-1).databaseValue,
        strict: true
      )
      public static let bitwiseOr = Self(sql: "|", neutralValue: 0.databaseValue, strict: true)

      init(sql: String, neutralValue: DatabaseValue, strict: Bool, bijective: Bool = false) {
        self.sql = sql
        self.neutralValue = neutralValue
        isStrictlyAssociative = strict
        isBijective = bijective
      }
    }

    var node: Node

    /// Whether the expression should be interpreted as JSON when embedded in JSON builders.
    var prefersJSON = false

    init(node: Node) {
      self.node = node
    }

    /// Creates an expression from raw SQL.
    public init(sql: String, arguments: StatementArguments = StatementArguments()) {
      node = .literal(SQL(sql: sql, arguments: arguments))
    }

    /// Creates an expression from an SQL literal.
    public init(literal: SQL) {
      node = .literal(literal)
    }

    init(_ literal: SQL) {
      node = .literal(literal)
    }

    init(column: String) {
      node = .column(column)
    }

    init(value: (any DatabaseValueConvertible)?) {
      node = .value(value?.databaseValue ?? .null)
    }

    /// The expression as an SQL literal.
    var literal: SQL {
      if case .literal(let sql) = node { return sql }
      return SQL(elements: [.expression(self)])
    }
  }

  extension SQLExpression: SQLSpecificExpressible {
    public var sqlExpression: SQLExpression { self }
  }

  // MARK: - Building expressions

  extension SQLExpression {
    static let null = SQLExpression(node: .value(.null))

    static func column(_ name: String) -> Self { .init(node: .column(name)) }

    static func qualifiedColumn(_ name: String, _ alias: TableAliasBase) -> Self {
      .init(node: .qualifiedColumn(name, alias))
    }

    static func databaseValue(_ value: DatabaseValue) -> Self { .init(node: .value(value)) }

    static func literal(_ sql: SQL) -> Self { .init(node: .literal(sql)) }

    static func subquery(_ subquery: SQLSubquery) -> Self { .init(node: .subquery(subquery)) }

    static func rowValue(_ expressions: [SQLExpression]) -> Self? {
      guard let first = expressions.first else { return nil }
      return expressions.count == 1 ? first : .init(node: .row(expressions))
    }

    static func cast(_ expression: SQLExpression, as storageClass: String) -> Self {
      .init(node: .cast(expression, storageClass))
    }

    static func between(
      _ expression: SQLExpression,
      _ lower: SQLExpression,
      _ upper: SQLExpression,
      negated: Bool = false
    ) -> Self {
      // Prefer `a BETWEEN b AND c COLLATE x` over `(a COLLATE x) BETWEEN b AND c`.
      if case .collated(let inner, let collation) = expression.node {
        return .collated(.between(inner, lower, upper, negated: negated), collation)
      }
      return .init(node: .between(expression, lower, upper, negated: negated))
    }

    static func binary(_ op: String, _ lhs: SQLExpression, _ rhs: SQLExpression) -> Self {
      if case .collated(let inner, let collation) = lhs.node {
        return .collated(.binary(op, inner, rhs), collation)
      }
      if case .collated(let inner, let collation) = rhs.node {
        return .collated(.binary(op, lhs, inner), collation)
      }
      return .init(node: .binary(op, lhs, rhs))
    }

    static func associative(_ op: AssociativeBinaryOperator, _ expressions: [SQLExpression]) -> Self
    {
      var flattened = expressions
      if op.isStrictlyAssociative {
        flattened = expressions.flatMap { expression -> [SQLExpression] in
          if case .associative(op, let children) = expression.node { return children }
          return [expression]
        }
      }
      guard let first = flattened.first else { return op.neutralValue.sqlExpression }
      return flattened.count == 1 ? first : .init(node: .associative(op, flattened))
    }

    static func compare(_ op: ComparisonOperator, _ lhs: SQLExpression, _ rhs: SQLExpression)
      -> Self
    {
      if case .collated(let inner, let collation) = lhs.node {
        return .collated(.compare(op, inner, rhs), collation)
      }
      if case .collated(let inner, let collation) = rhs.node {
        return .collated(.compare(op, lhs, inner), collation)
      }
      return .init(node: .compare(op, lhs, rhs))
    }

    static func equal(_ lhs: SQLExpression, _ rhs: SQLExpression) -> Self {
      if case .value(let value) = rhs.node, value.isNull { return .compare(.is, lhs, .null) }
      if case .value(let value) = lhs.node, value.isNull { return .compare(.is, rhs, .null) }
      return .compare(.equal, lhs, rhs)
    }

    static func `in`(
      _ expression: SQLExpression,
      _ collection: SQLCollection,
      negated: Bool = false
    )
      -> Self
    {
      .init(node: .in(expression, collection, negated: negated))
    }

    static func exists(_ subquery: SQLSubquery, negated: Bool = false) -> Self {
      .init(node: .exists(subquery, negated: negated))
    }

    static func unary(_ op: String, _ expression: SQLExpression) -> Self {
      .init(node: .unary(op, expression))
    }

    static func not(_ expression: SQLExpression) -> Self { .init(node: .not(expression)) }

    static func collated(_ expression: SQLExpression, _ collation: String) -> Self {
      switch expression.node {
      case .in(let inner, let collection, let negated):
        // The collation of `x IN (...)` is the collation of x.
        return .in(.collated(inner, collation), collection, negated: negated)
      case .associative(let op, let children):
        return .associative(op, children.map { .collated($0, collation) })
      default:
        return .init(node: .collated(expression, collation))
      }
    }

    static func tableMatch(_ alias: TableAliasBase, _ pattern: SQLExpression) -> Self {
      .init(node: .tableMatch(alias, pattern))
    }

    static let countAll = SQLExpression(node: .countAll)

    static let fastPrimaryKey = SQLExpression(node: .fastPrimaryKey)

    static func qualifiedExists(_ alias: TableAliasBase) -> Self {
      .init(node: .qualifiedExists(alias, negated: false))
    }

    static func isEmpty(_ expression: SQLExpression, negated: Bool = false) -> Self {
      .init(node: .isEmpty(expression, negated: negated))
    }

    private static let pureFunctions: Set<String> = [
      "ABS", "CHAR", "COALESCE", "GLOB", "HEX", "IFNULL", "IIF", "INSTR", "JSON", "JSON_ARRAY",
      "JSON_GROUP_ARRAY", "JSON_GROUP_OBJECT", "JSON_INSERT", "JSON_OBJECT", "JSON_PATCH",
      "JSON_REMOVE", "JSON_REPLACE", "JSON_SET", "JSON_QUOTE", "JSONB", "JSONB_ARRAY",
      "JSONB_EXTRACT", "JSONB_GROUP_ARRAY", "JSONB_GROUP_OBJECT", "JSONB_INSERT", "JSONB_OBJECT",
      "JSONB_PATCH", "JSONB_REMOVE", "JSONB_REPLACE", "JSONB_SET", "LENGTH", "LIKE", "LIKELIHOOD",
      "LIKELY", "LOAD_EXTENSION", "LOWER", "LTRIM", "NULLIF", "PRINTF", "QUOTE", "REPLACE",
      "ROUND", "RTRIM", "SOUNDEX", "SQLITE_COMPILEOPTION_GET", "SQLITE_COMPILEOPTION_USED",
      "SQLITE_SOURCE_ID", "SQLITE_VERSION", "SUBSTR", "TRIM", "TYPEOF", "UNICODE", "UNLIKELY",
      "UPPER", "ZEROBLOB"
    ]

    private static let aggregateFunctions: Set<String> = [
      "AVG", "COUNT", "GROUP_CONCAT", "JSON_GROUP_ARRAY", "JSON_GROUP_OBJECT", "MAX", "MIN", "SUM",
      "TOTAL"
    ]

    /// A function call; known aggregate functions produce aggregate expressions.
    static func function(_ name: String, _ arguments: [SQLExpression], isPure: Bool? = nil) -> Self
    {
      let upper = name.uppercased()
      if (upper == "MAX" || upper == "MIN") && arguments.count > 1 {
        return .init(node: .function(name, arguments, isPure: true))
      }
      if aggregateFunctions.contains(upper) {
        return .aggregate(name, arguments)
      }
      return .init(
        node: .function(name, arguments, isPure: isPure ?? pureFunctions.contains(upper))
      )
    }

    static func aggregate(
      _ name: String,
      _ arguments: [SQLExpression],
      distinct: Bool = false,
      ordering: SQLOrdering? = nil,
      filter: SQLExpression? = nil
    ) -> Self {
      .init(
        node: .aggregate(
          AggregateInvocation(
            name: name,
            arguments: arguments,
            isDistinct: distinct,
            ordering: ordering,
            filter: filter
          )
        )
      )
    }

    /// Applies a boolean test, negating comparisons when possible.
    func `is`(_ test: BooleanTest) -> SQLExpression {
      func generic() -> SQLExpression {
        switch test {
        case .true: return .compare(.equal, self, true.sqlExpression)
        case .false: return .compare(.equal, self, false.sqlExpression)
        case .falsey: return .not(self)
        }
      }
      switch node {
      case .value(let value):
        switch value.storage {
        case .null:
          return .null
        case .int64(let int) where int == 0 || int == 1:
          return (test == .true ? int == 1 : int == 0).sqlExpression
        default:
          return generic()
        }
      case .between(let e, let lower, let upper, let negated) where test == .falsey:
        return .init(node: .between(e, lower, upper, negated: !negated))
      case .like(let lhs, let rhs, let escape, let negated) where test == .falsey:
        return .init(node: .like(lhs, rhs, escape: escape, negated: !negated))
      case .exists(let subquery, let negated) where test == .falsey:
        return .init(node: .exists(subquery, negated: !negated))
      case .in(let e, let collection, let negated) where test == .falsey:
        return .init(node: .in(e, collection, negated: !negated))
      case .compare(let op, let lhs, let rhs) where test == .falsey:
        return .compare(op.negated, lhs, rhs)
      case .collated(let e, let collation):
        return .collated(e.is(test), collation)
      case .isEmpty(let e, let negated):
        return test == .true ? self : .init(node: .isEmpty(e, negated: !negated))
      case .qualifiedExists(let alias, let negated) where test == .falsey:
        return .init(node: .qualifiedExists(alias, negated: !negated))
      default:
        return generic()
      }
    }
  }

  // MARK: - SQL generation

  extension SQLExpression {
    func sql(_ context: SQLGenerationContext, wrappedInParenthesis wrapped: Bool = false) throws
      -> String
    {
      func wrap(_ sql: String) -> String { wrapped ? "(" + sql + ")" : sql }
      switch node {
      case .column(let name):
        return quoted(name)
      case .qualifiedColumn(let name, let alias):
        if let qualifier = context.qualifier(for: alias) {
          return quoted(qualifier) + "." + quoted(name)
        }
        return quoted(name)
      case .value(let value):
        return try context.valueSQL(value)
      case .row(let expressions):
        return try "(" + expressions.map { try $0.sql(context) }.joined(separator: ", ") + ")"
      case .subquery(let subquery):
        return try "(" + subquery.sql(context) + ")"
      case .literal(let literal):
        return try wrap(literal.sql(context))
      case .cast(let expression, let storageClass):
        return try "CAST(" + expression.sql(context) + " AS " + storageClass + ")"
      case .between(let expression, let lower, let upper, let negated):
        return try wrap(
          expression.sql(context, wrappedInParenthesis: true)
            + (negated ? " NOT BETWEEN " : " BETWEEN ")
            + lower.sql(context, wrappedInParenthesis: true) + " AND "
            + upper.sql(context, wrappedInParenthesis: true)
        )
      case .binary(let op, let lhs, let rhs):
        return try wrap(
          lhs.sql(context, wrappedInParenthesis: true) + " " + op + " "
            + rhs.sql(context, wrappedInParenthesis: true)
        )
      case .like(let lhs, let rhs, let escape, let negated):
        var sql =
          try lhs.sql(context, wrappedInParenthesis: true)
          + (negated ? " NOT LIKE " : " LIKE ") + rhs.sql(context, wrappedInParenthesis: true)
        if let escape {
          sql += try " ESCAPE " + escape.sql(context, wrappedInParenthesis: true)
        }
        return wrap(sql)
      case .associative(let op, let expressions):
        return try wrap(
          expressions.map { try $0.sql(context, wrappedInParenthesis: true) }
            .joined(separator: " " + op.sql + " ")
        )
      case .exists(let subquery, let negated):
        return try wrap((negated ? "NOT EXISTS (" : "EXISTS (") + subquery.sql(context) + ")")
      case .in(let expression, let collection, let negated):
        return try wrap(
          expression.sql(context, wrappedInParenthesis: true) + (negated ? " NOT IN " : " IN ")
            + collection.sql(context)
        )
      case .unary(let op, let expression):
        return try wrap(op + expression.sql(context, wrappedInParenthesis: true))
      case .compare(let op, let lhs, let rhs):
        return try wrap(
          lhs.sql(context, wrappedInParenthesis: true) + " " + op.rawValue + " "
            + rhs.sql(context, wrappedInParenthesis: true)
        )
      case .tableMatch(let alias, let pattern):
        return try wrap(
          quoted(context.resolvedName(for: alias)) + " MATCH "
            + pattern.sql(context, wrappedInParenthesis: true)
        )
      case .not(let expression):
        return try wrap("NOT " + expression.sql(context, wrappedInParenthesis: true))
      case .collated(let expression, let collation):
        return try wrap(expression.sql(context) + " COLLATE " + collation)
      case .countAll:
        return "COUNT(*)"
      case .function(let name, let arguments, _):
        return try name + "(" + arguments.map { try $0.sql(context) }.joined(separator: ", ") + ")"
      case .aggregate(let invocation):
        var sql = invocation.name + (invocation.isDistinct ? "(DISTINCT " : "(")
        sql += try invocation.arguments.map { try $0.sql(context) }.joined(separator: ", ")
        if let ordering = invocation.ordering {
          sql += try " ORDER BY " + ordering.sql(context)
        }
        sql += ")"
        if let filter = invocation.filter {
          sql += try " FILTER (WHERE " + filter.sql(context) + ")"
          return wrap(sql)
        }
        return sql
      case .isEmpty(let expression, let negated):
        return try wrap(
          expression.sql(context, wrappedInParenthesis: true) + (negated ? " > 0" : " = 0")
        )
      case .fastPrimaryKey:
        // Unqualified primary keys appear in literal contexts only.
        return "rowid"
      case .qualifiedFastPrimaryKey(let alias):
        let column = try context.requireDatabase().fastPrimaryKeyColumn(alias.tableName)
        return try SQLExpression.qualifiedColumn(column, alias)
          .sql(context, wrappedInParenthesis: wrapped)
      case .qualifiedExists(let alias, let negated):
        let columns = try context.requireDatabase().existenceCheckColumns(alias.tableName)
        let expression: SQLExpression
        if negated {
          expression = .associative(
            .and,
            columns.map { .compare(.is, .qualifiedColumn($0, alias), .null) }
          )
        } else {
          expression = .associative(
            .or,
            columns.map { .compare(.isNot, .qualifiedColumn($0, alias), .null) }
          )
        }
        return try expression.sql(context, wrappedInParenthesis: wrapped)
      }
    }

    /// The SQL of the expression with values rendered as SQL literals.
    func quotedSQL(_ db: Database) throws -> String {
      let context = SQLGenerationContext(db, literalValues: true)
      return try sql(context)
    }
  }

  // MARK: - Qualification and analysis

  extension SQLExpression {
    func qualified(with alias: TableAliasBase) -> SQLExpression {
      var result = qualifiedNode(with: alias)
      result.prefersJSON = prefersJSON
      return result
    }

    private func qualifiedNode(with alias: TableAliasBase) -> SQLExpression {
      func q(_ e: SQLExpression) -> SQLExpression { e.qualified(with: alias) }
      switch node {
      case .column(let name):
        return .qualifiedColumn(name, alias)
      case .qualifiedColumn, .value, .subquery, .countAll, .qualifiedFastPrimaryKey,
        .qualifiedExists, .tableMatch:
        return self
      case .row(let expressions):
        return .init(node: .row(expressions.map(q)))
      case .literal(let literal):
        return .init(node: .literal(literal.qualified(with: alias)))
      case .cast(let e, let storageClass):
        return .init(node: .cast(q(e), storageClass))
      case .between(let e, let lower, let upper, let negated):
        return .init(node: .between(q(e), q(lower), q(upper), negated: negated))
      case .binary(let op, let lhs, let rhs):
        return .init(node: .binary(op, q(lhs), q(rhs)))
      case .like(let lhs, let rhs, let escape, let negated):
        return .init(node: .like(q(lhs), q(rhs), escape: escape.map(q), negated: negated))
      case .associative(let op, let expressions):
        return .init(node: .associative(op, expressions.map(q)))
      case .exists:
        return self
      case .in(let e, let collection, let negated):
        return .init(node: .in(q(e), collection.qualified(with: alias), negated: negated))
      case .unary(let op, let e):
        return .init(node: .unary(op, q(e)))
      case .compare(let op, let lhs, let rhs):
        return .init(node: .compare(op, q(lhs), q(rhs)))
      case .not(let e):
        return .init(node: .not(q(e)))
      case .collated(let e, let collation):
        return .init(node: .collated(q(e), collation))
      case .function(let name, let arguments, let isPure):
        return .init(node: .function(name, arguments.map(q), isPure: isPure))
      case .aggregate(var invocation):
        invocation.arguments = invocation.arguments.map(q)
        invocation.ordering = invocation.ordering?.qualified(with: alias)
        invocation.filter = invocation.filter.map(q)
        return .init(node: .aggregate(invocation))
      case .isEmpty(let e, let negated):
        return .init(node: .isEmpty(q(e), negated: negated))
      case .fastPrimaryKey:
        return .init(node: .qualifiedFastPrimaryKey(alias))
      }
    }

    /// The column of `alias` that this expression designates, if any.
    func column(_ db: Database, for alias: TableAliasBase, acceptsBijection: Bool = false) throws
      -> String?
    {
      switch node {
      case .qualifiedColumn(let name, let a):
        return a == alias ? name : nil
      case .associative(let op, let expressions):
        guard acceptsBijection && op.isBijective else { return nil }
        let variables = expressions.filter { !$0.isConstantInRequest }
        return variables.count == 1
          ? try variables[0].column(db, for: alias, acceptsBijection: true) : nil
      case .unary(let op, let e):
        return acceptsBijection && op == "-"
          ? try e.column(db, for: alias, acceptsBijection: true) : nil
      case .collated(let e, _):
        return try e.column(db, for: alias, acceptsBijection: acceptsBijection)
      case .function(let name, let arguments, _) where acceptsBijection:
        let upper = name.uppercased()
        if ["HEX", "QUOTE"].contains(upper) && arguments.count == 1 {
          return try arguments[0].column(db, for: alias, acceptsBijection: true)
        }
        if upper == "IFNULL" && arguments.count == 2 && arguments[1].isConstantInRequest {
          return try arguments[0].column(db, for: alias, acceptsBijection: true)
        }
        return nil
      case .qualifiedFastPrimaryKey(let a):
        return a == alias ? try db.fastPrimaryKeyColumn(alias.tableName) : nil
      default:
        return nil
      }
    }

    /// The columns of `alias` that are tested for equality with constants.
    func identifyingColumns(_ db: Database, for alias: TableAliasBase) throws -> Set<String> {
      switch node {
      case .row(let expressions):
        return try expressions.reduce(into: []) {
          try $0.formUnion($1.identifyingColumns(db, for: alias))
        }
      case .associative(let op, let expressions) where op == .and:
        return try expressions.reduce(into: []) {
          try $0.formUnion($1.identifyingColumns(db, for: alias))
        }
      case .compare(let op, let lhs, let rhs) where op == .equal || op == .is:
        if let column = try lhs.column(db, for: alias, acceptsBijection: true),
          rhs.isConstantInRequest
        {
          return [column]
        }
        if let column = try rhs.column(db, for: alias, acceptsBijection: true),
          lhs.isConstantInRequest
        {
          return [column]
        }
        return []
      case .collated(let e, _):
        return try e.identifyingColumns(db, for: alias)
      default:
        return []
      }
    }

    /// Whether a filter provably selects no row (`WHERE 0`, `WHERE NULL`).
    var selectsNoRow: Bool {
      switch node {
      case .value(let value):
        return value.isNull || value == false.databaseValue
      case .associative(let op, let expressions) where op == .and:
        return expressions.contains(where: \.selectsNoRow)
      case .associative(let op, let expressions) where op == .or:
        return expressions.allSatisfy(\.selectsNoRow)
      case .collated(let e, _):
        return e.selectsNoRow
      default:
        return false
      }
    }

    var isConstantInRequest: Bool {
      switch node {
      case .value:
        return true
      case .row(let expressions), .associative(_, let expressions):
        return expressions.allSatisfy(\.isConstantInRequest)
      case .cast(let e, _), .unary(_, let e), .not(let e), .isEmpty(let e, _),
        .collated(let e, _):
        return e.isConstantInRequest
      case .between(let e, let lower, let upper, _):
        return e.isConstantInRequest && lower.isConstantInRequest && upper.isConstantInRequest
      case .binary(_, let lhs, let rhs), .compare(_, let lhs, let rhs):
        return lhs.isConstantInRequest && rhs.isConstantInRequest
      case .in(let e, let collection, _):
        guard let expressions = collection.expressions else { return false }
        return e.isConstantInRequest && expressions.allSatisfy(\.isConstantInRequest)
      case .function(_, let arguments, let isPure):
        return isPure && arguments.allSatisfy(\.isConstantInRequest)
      default:
        return false
      }
    }

    var isAggregate: Bool {
      switch node {
      case .row(let expressions), .associative(_, let expressions):
        return expressions.contains(where: \.isAggregate)
      case .between(let e, _, _, _), .unary(_, let e), .not(let e), .collated(let e, _),
        .isEmpty(let e, _):
        return e.isAggregate
      case .binary(_, let lhs, let rhs), .compare(_, let lhs, let rhs):
        return lhs.isAggregate || rhs.isAggregate
      case .in(let e, let collection, _):
        return e.isAggregate || (collection.expressions?.contains(where: \.isAggregate) ?? false)
      case .countAll, .aggregate:
        return true
      default:
        return false
      }
    }
  }

  extension Database {
    /// Whether a table has a rowid (it is not a WITHOUT ROWID table).
    func tableHasRowID(_ table: String) throws -> Bool {
      let key = try primaryKey(table)
      if key.isRowID { return true }
      return (try? access.statementInfo("SELECT rowid FROM \(quoted(table)) LIMIT 0")) != nil
    }

    /// The column that identifies rows in a table, preferring its rowid.
    func fastPrimaryKeyColumn(_ table: String) throws -> String {
      let key = try primaryKey(table)
      if let column = key.rowIDColumn { return column }
      if try tableHasRowID(table) { return Column.rowID.name }
      guard key.columns.count == 1 else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "Not implemented for WITHOUT ROWID table with a multi-columns primary key"
        )
      }
      return key.columns[0]
    }

    /// Columns that are NOT NULL for any existing row, used to test joined rows for existence.
    func existenceCheckColumns(_ table: String) throws -> [String] {
      // Tables, and views whose primary key is defined by the schema source, check their
      // primary key. Other views check all columns.
      let isTable = try tableExists(table)
      if isTable || schemaSource != nil, let key = try? primaryKey(table) {
        if let column = key.rowIDColumn { return [column] }
        if try isTable && tableHasRowID(table) { return [Column.rowID.name] }
        return key.columns
      }
      return try columns(in: table).map(\.name)
    }
  }

  // MARK: - Joining expressions

  extension Sequence where Element: SQLSpecificExpressible {
    /// Joins expressions with an associative operator.
    public func joined(operator: SQLExpression.AssociativeBinaryOperator) -> SQLExpression {
      .associative(`operator`, map(\.sqlExpression))
    }
  }

  extension Sequence where Element == any SQLSpecificExpressible {
    /// Joins expressions with an associative operator.
    public func joined(operator: SQLExpression.AssociativeBinaryOperator) -> SQLExpression {
      .associative(`operator`, map(\.sqlExpression))
    }
  }
#endif
