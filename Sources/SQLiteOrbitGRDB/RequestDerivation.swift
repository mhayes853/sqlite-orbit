#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  extension QueryInterfaceRequest {
    public func none() -> Self {
      filter(sql: "0")
    }

    public func select(_ selection: [any SQLSelectable]) -> Self {
      selecting(selection)
    }

    public func select<T>(_ selection: [any SQLSelectable], as type: T.Type = T.self)
      -> QueryInterfaceRequest<T>
    {
      asRequest(of: type).selecting(selection)
    }

    public func select(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      selecting([SQLExpression(sql: sql, arguments: arguments)])
    }

    public func select(literal: SQL) -> Self {
      select(sql: literal.sql, arguments: literal.arguments)
    }

    public func select<T>(
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      as type: T.Type = T.self
    ) -> QueryInterfaceRequest<T> {
      select(sql: sql, arguments: arguments).asRequest(of: type)
    }

    public func select<T>(literal: SQL, as type: T.Type = T.self) -> QueryInterfaceRequest<T> {
      select(literal: literal).asRequest(of: type)
    }

    public func annotated(with selection: any SQLSelectable...) -> Self {
      annotated(with: selection)
    }

    public func annotated(with selection: [any SQLSelectable]) -> Self {
      let fragments = selection.map(\.sqlSelection)
      return annotatedWhenConnected(with: { _ in fragments.map(SQLExpression.init) })
    }

    public func filter(literal: SQL) -> Self {
      filter(sql: literal.sql, arguments: literal.arguments)
    }

    public func order(_ terms: [any SQLOrderingTerm]) -> Self {
      ordered(by: terms)
    }

    public func order(literal: SQL) -> Self {
      order(sql: literal.sql, arguments: literal.arguments)
    }

    public func group(_ expressions: [any SQLExpressible]) -> Self {
      let fragments = expressions.map { $0.sqlExpression.literal }
      return groupWhenConnected { _ in fragments.map(SQLExpression.init) }
    }

    public func group(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      group([SQLExpression(sql: sql, arguments: arguments)])
    }

    public func group(literal: SQL) -> Self {
      group(sql: literal.sql, arguments: literal.arguments)
    }

    public func having(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
      having(SQLExpression(sql: "(" + sql + ")", arguments: arguments))
    }

    public func having(literal: SQL) -> Self {
      having(sql: literal.sql, arguments: literal.arguments)
    }

    public func orderByPrimaryKey() -> Self {
      let table = table
      return orderWhenConnected { try $0.primaryKey(table).columns.map(Column.init) }
    }

    public func groupByPrimaryKey() -> Self {
      let table = table
      return groupWhenConnected { try $0.primaryKey(table).columns.map(Column.init) }
    }

    public func selectPrimaryKey<T>(as type: T.Type = T.self) -> QueryInterfaceRequest<T> {
      let table = table
      return selectWhenConnected { try $0.primaryKey(table).columns.map(Column.init) }
        .asRequest(of: type)
    }
  }

  extension QueryInterfaceRequest where RowDecoder: Identifiable {
    public func selectID() -> QueryInterfaceRequest<RowDecoder.ID> {
      selectPrimaryKey()
    }
  }

  extension TableRecord {
    public static func select(_ selection: [any SQLSelectable]) -> QueryInterfaceRequest<Self> {
      all().select(selection)
    }

    public static func select(sql: String, arguments: StatementArguments = StatementArguments())
      -> QueryInterfaceRequest<Self>
    {
      all().select(sql: sql, arguments: arguments)
    }

    public static func select(literal: SQL) -> QueryInterfaceRequest<Self> {
      all().select(literal: literal)
    }

    public static func select<T>(_ selection: [any SQLSelectable], as type: T.Type = T.self)
      -> QueryInterfaceRequest<T>
    {
      all().select(selection, as: type)
    }

    public static func select<T>(
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      as type: T.Type = T.self
    ) -> QueryInterfaceRequest<T> {
      all().select(sql: sql, arguments: arguments, as: type)
    }

    public static func select<T>(literal: SQL, as type: T.Type = T.self) -> QueryInterfaceRequest<T>
    {
      all().select(literal: literal, as: type)
    }

    public static func annotated(with selection: any SQLSelectable...) -> QueryInterfaceRequest<
      Self
    > {
      all().annotated(with: selection)
    }

    public static func annotated(with selection: [any SQLSelectable]) -> QueryInterfaceRequest<Self>
    {
      all().annotated(with: selection)
    }

    public static func filter(literal: SQL) -> QueryInterfaceRequest<Self> {
      all().filter(literal: literal)
    }

    public static func order(_ terms: [any SQLOrderingTerm]) -> QueryInterfaceRequest<Self> {
      all().order(terms)
    }

    public static func order(literal: SQL) -> QueryInterfaceRequest<Self> {
      all().order(literal: literal)
    }

    public static func orderByPrimaryKey() -> QueryInterfaceRequest<Self> {
      all().orderByPrimaryKey()
    }

    public static func selectPrimaryKey<T>(as type: T.Type = T.self) -> QueryInterfaceRequest<T> {
      all().selectPrimaryKey(as: type)
    }

  }

  extension Table {
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

    public func annotated(with selection: any SQLSelectable...) -> QueryInterfaceRequest<RowDecoder>
    {
      all().annotated(with: selection)
    }

    public func annotated(with selection: [any SQLSelectable]) -> QueryInterfaceRequest<RowDecoder>
    {
      all().annotated(with: selection)
    }

    public func filter(literal: SQL) -> QueryInterfaceRequest<RowDecoder> {
      all().filter(literal: literal)
    }

    public func order(_ terms: [any SQLOrderingTerm]) -> QueryInterfaceRequest<RowDecoder> {
      all().order(terms)
    }

    public func order(literal: SQL) -> QueryInterfaceRequest<RowDecoder> {
      all().order(literal: literal)
    }

    public func orderByPrimaryKey() -> QueryInterfaceRequest<RowDecoder> {
      all().orderByPrimaryKey()
    }

    public func selectPrimaryKey<T>(as type: T.Type = T.self) -> QueryInterfaceRequest<T> {
      all().selectPrimaryKey(as: type)
    }

  }

  extension TableRecord where Self: Identifiable {
    public static func selectID() -> QueryInterfaceRequest<ID> {
      all().selectID()
    }
  }

  extension Table where RowDecoder: Identifiable {
    public func selectID() -> QueryInterfaceRequest<RowDecoder.ID> {
      all().selectID()
    }
  }
#endif
