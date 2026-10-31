#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public struct IndexOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let ifNotExists = Self(rawValue: 1)
    public static let unique = Self(rawValue: 2)
  }

  public struct ViewOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let ifNotExists = Self(rawValue: 1)
    public static let temporary = Self(rawValue: 2)
  }

  extension ColumnDefinition {
    public enum GeneratedColumnQualification: Sendable {
      case virtual, stored

      var sql: String {
        self == .virtual ? "VIRTUAL" : "STORED"
      }
    }

    @discardableResult
    public func defaults(sql: String) -> Self {
      defaultClause = SQL(sql: "DEFAULT " + sql)
      return self
    }

    @discardableResult
    public func check(_ condition: (Column) -> any SQLExpressible) -> Self {
      checkClauses.append(
        SQL(sql: "CHECK (") + SQL(elements: [.expression(condition(Column(name)).sqlExpression)])
          + SQL(sql: ")")
      )
      return self
    }

    @discardableResult
    public func generatedAs(sql: String, _ qualification: GeneratedColumnQualification = .virtual)
      -> Self
    {
      generatedAs(SQLExpression(sql: sql), qualification)
    }

    @discardableResult
    public func generatedAs(
      _ expression: some SQLExpressible,
      _ qualification: GeneratedColumnQualification = .virtual
    ) -> Self {
      generatedClause =
        SQL(sql: "GENERATED ALWAYS AS (") + SQL(elements: [.expression(expression.sqlExpression)])
        + SQL(sql: ") " + qualification.sql)
      return self
    }

    @discardableResult
    public func collate(_ collation: DatabaseCollation) -> Self {
      collate(collation.name)
    }
  }

  extension TableDefinition {
    public func check(_ expression: some SQLExpressible) {
      checkConstraints.append(
        SQL(sql: "CHECK (") + SQL(elements: [.expression(expression.sqlExpression)])
          + SQL(sql: ")")
      )
    }

    public func constraint(sql: String) {
      literalConstraints.append(SQL(sql: sql))
    }

    public func constraint(literal: SQL) {
      literalConstraints.append(literal)
    }
  }

  extension Database {
    public func create(
      index name: String,
      on table: String,
      columns: [String],
      options: IndexOptions,
      condition: (any SQLExpressible)? = nil
    ) throws {
      try create(
        index: name,
        on: table,
        expressions: columns.map(Column.init),
        options: options,
        condition: condition
      )
    }

    public func create(
      index name: String,
      on table: String,
      expressions: [any SQLExpressible],
      options: IndexOptions = [],
      condition: (any SQLExpressible)? = nil
    ) throws {
      try execute(
        sql: indexSQL(
          self,
          name: name,
          table: table,
          expressions: expressions.map(\.sqlExpression),
          options: options,
          condition: condition?.sqlExpression
        )
      )
    }

    public func create(
      indexOn table: String,
      columns: [String],
      options: IndexOptions = [],
      condition: (any SQLExpressible)? = nil
    ) throws {
      try create(
        index: "index_\(table)_on_\(columns.joined(separator: "_"))",
        on: table,
        columns: columns,
        options: options,
        condition: condition
      )
    }

    public func drop(indexOn table: String, columns: [String]) throws {
      let columns = columns.map { $0.lowercased() }
      if let index = try indexes(on: table)
        .first(where: { $0.columns.map { $0.lowercased() } == columns })
      {
        try drop(index: index.name)
      }
    }

    public func reindex(collation: DatabaseCollation) throws {
      try execute(sql: "REINDEX " + collation.name)
    }

    public func create(
      view name: String,
      options: ViewOptions = [],
      columns: [String]? = nil,
      as request: some FetchRequest
    ) throws {
      try create(view: name, options: options, columns: columns, asLiteral: request.sql(in: self))
    }

    public func create(
      view name: String,
      options: ViewOptions = [],
      columns: [String]? = nil,
      asLiteral literal: SQL
    ) throws {
      let sql =
        SQL(
          sql: "CREATE " + (options.contains(.temporary) ? "TEMPORARY " : "") + "VIEW "
            + (options.contains(.ifNotExists) ? "IF NOT EXISTS " : "") + quoted(name)
            + (columns.map { " (" + $0.map(quoted).joined(separator: ", ") + ")" } ?? "") + " AS "
        ) + literal
      try execute(sql: sql.expandedSQL(in: self))
    }

    public func drop(view name: String) throws {
      try execute(sql: "DROP VIEW " + quoted(name))
    }
  }
#endif
