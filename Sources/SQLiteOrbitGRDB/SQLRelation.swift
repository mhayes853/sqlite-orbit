#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// A value that may depend on the database schema, resolved when a request is executed.
  struct Deferred<Value>: Sendable {
    let resolve: @Sendable (Database) throws -> Value

    init(_ resolve: @escaping @Sendable (Database) throws -> Value) {
      self.resolve = resolve
    }

    init(value: Value) where Value: Sendable {
      resolve = { _ in value }
    }

    func map<T>(_ transform: @escaping @Sendable (Value) throws -> T) -> Deferred<T> {
      let resolve = self.resolve
      return Deferred<T> { try transform(resolve($0)) }
    }
  }

  struct SQLLimit: Sendable {
    var limit: Int
    var offset: Int?

    var sql: String {
      offset.map { "\(limit) OFFSET \($0)" } ?? "\(limit)"
    }
  }

  struct SQLSource: Sendable {
    var tableName: String
    var alias: TableAliasBase?

    func aliased(_ alias: TableAliasBase) -> SQLSource {
      if let existing = self.alias {
        alias.becomeProxy(of: existing)
        return self
      }
      alias.setTableName(tableName)
      return SQLSource(tableName: tableName, alias: alias)
    }
  }

  /// How a joined relation relates to its parent.
  enum SQLAssociationCondition: Sendable {
    case expression(@Sendable (_ left: TableAliasBase, _ right: TableAliasBase) -> SQLExpression?)
    case foreignKey(SQLForeignKeyCondition)

    static let none = SQLAssociationCondition.expression { _, _ in nil }

    func reversed(to destinationTable: String) -> SQLAssociationCondition {
      switch self {
      case .expression(let condition):
        return .expression { condition($1, $0) }
      case .foreignKey(let condition):
        return .foreignKey(condition.reversed(to: destinationTable))
      }
    }

    func joinExpression(_ db: Database, left: TableAliasBase, right: TableAliasBase) throws
      -> SQLExpression?
    {
      switch self {
      case .expression(let condition):
        return condition(left, right)
      case .foreignKey(let condition):
        let mapping = try condition.joinMapping(db, from: left.tableName)
        return mapping.joinExpression(left: left, right: right)
      }
    }
  }

  /// The query part of a request: source table, selection, filters, ordering, and joins.
  struct SQLRelation: Sendable {
    struct Child: Sendable {
      enum Kind: Sendable {
        case oneOptional, oneRequired, all, bridge
      }

      var kind: Kind
      var condition: SQLAssociationCondition
      var relation: SQLRelation

      var impactsParentCount: Bool {
        kind == .oneOptional || kind == .oneRequired
      }
    }

    struct Ordering: Sendable {
      private enum Element: Sendable {
        case terms(Deferred<[SQLOrdering]>)
        case ordering(Ordering)
      }

      private var elements: [Element] = []
      private(set) var isReversed = false

      init() {}

      init(_ orderings: Deferred<[SQLOrdering]>) {
        elements = [.terms(orderings)]
      }

      var isEmpty: Bool { elements.isEmpty }

      var reversed: Ordering {
        var result = self
        result.isReversed.toggle()
        return result
      }

      /// Appends another ordering, which keeps its own reversal state.
      func appending(_ other: Ordering) -> Ordering {
        var result = self
        result.elements.append(.ordering(other))
        return result
      }

      func qualified(with alias: TableAliasBase) -> Ordering {
        var result = self
        result.elements = elements.map {
          switch $0 {
          case .terms(let terms): return .terms(terms.map { $0.map { $0.qualified(with: alias) } })
          case .ordering(let ordering): return .ordering(ordering.qualified(with: alias))
          }
        }
        return result
      }

      func resolve(_ db: Database) throws -> [SQLOrdering] {
        try resolve(db, reversed: false)
      }

      private func resolve(_ db: Database, reversed outer: Bool) throws -> [SQLOrdering] {
        let reversed = outer != isReversed
        return try elements.flatMap { element -> [SQLOrdering] in
          switch element {
          case .ordering(let ordering):
            return try ordering.resolve(db, reversed: reversed)
          case .terms(let terms):
            let orderings = try terms.resolve(db)
            guard reversed else { return orderings }
            return try orderings.map {
              guard let reversed = $0.reversed else {
                throw DatabaseError(
                  resultCode: .SQLITE_MISUSE,
                  message: "ordering SQL literals cannot be reversed; order by expressions instead"
                )
              }
              return reversed
            }
          }
        }
      }
    }

    var source: SQLSource
    var selection: Deferred<[SQLSelection]>
    var filter: Deferred<SQLExpression>?
    var ordering = Ordering()
    var ctes: [(String, SQLCTE)] = []
    var children: [(String, Child)] = []
    var isDistinct = false
    var group: Deferred<[SQLExpression]>?
    var having: Deferred<SQLExpression>?
    var limit: SQLLimit?

    static func all(fromTable tableName: String, selection: [SQLSelection] = [.allColumns]) -> Self
    {
      SQLRelation(
        source: SQLSource(tableName: tableName, alias: nil),
        selection: Deferred(value: selection)
      )
    }

    func with(_ update: (inout Self) throws -> Void) rethrows -> Self {
      var result = self
      try update(&result)
      return result
    }

    func selectWhenConnected(_ selection: @escaping @Sendable (Database) throws -> [SQLSelection])
      -> Self
    {
      with { $0.selection = Deferred(selection) }
    }

    func select(_ selection: [SQLSelection]) -> Self {
      with { $0.selection = Deferred(value: selection) }
    }

    func selectOnly(_ selection: [SQLSelection]) -> Self {
      select(selection)
        .with {
          $0.isDistinct = false
          $0.children = $0.children.map { key, child in
            var child = child
            child.relation = child.relation.selectOnly([])
            return (key, child)
          }
        }
    }

    func annotatedWhenConnected(
      with selection: @escaping @Sendable (Database) throws -> [SQLSelection]
    ) -> Self {
      let old = self.selection
      return with { $0.selection = Deferred { try old.resolve($0) + selection($0) } }
    }

    func filterWhenConnected(_ predicate: @escaping @Sendable (Database) throws -> SQLExpression)
      -> Self
    {
      with {
        if let old = $0.filter {
          $0.filter = Deferred { db in try .associative(.and, [old.resolve(db), predicate(db)]) }
        } else {
          $0.filter = Deferred(predicate)
        }
      }
    }

    func filter(_ predicate: SQLExpression) -> Self {
      filterWhenConnected { _ in predicate }
    }

    func orderWhenConnected(_ orderings: @escaping @Sendable (Database) throws -> [SQLOrdering])
      -> Self
    {
      with { $0.ordering = Ordering(Deferred(orderings)) }
    }

    func reversed() -> Self {
      with { $0.ordering = $0.ordering.reversed }
    }

    func unordered() -> Self {
      with {
        $0.ordering = Ordering()
        $0.children = $0.children.map { key, child in
          var child = child
          child.relation = child.relation.unordered()
          return (key, child)
        }
      }
    }

    func unorderedUnlessLimited() -> Self {
      limit == nil ? unordered() : self
    }

    func groupWhenConnected(_ expressions: @escaping @Sendable (Database) throws -> [SQLExpression])
      -> Self
    {
      with { $0.group = Deferred(expressions) }
    }

    func havingWhenConnected(_ predicate: @escaping @Sendable (Database) throws -> SQLExpression)
      -> Self
    {
      with {
        if let old = $0.having {
          $0.having = Deferred { db in try .associative(.and, [old.resolve(db), predicate(db)]) }
        } else {
          $0.having = Deferred(predicate)
        }
      }
    }

    func aliased(_ alias: TableAliasBase) -> Self {
      with { $0.source = $0.source.aliased(alias) }
    }

    func appendingCTE(_ name: String, _ cte: SQLCTE) -> Self {
      with {
        if let index = $0.ctes.firstIndex(where: { $0.0 == name }) {
          $0.ctes[index].1 = cte
        } else {
          $0.ctes.append((name, cte))
        }
      }
    }

    func appendingChild(_ child: Child, forKey key: String) -> Self {
      with { relation in
        if let index = relation.children.firstIndex(where: { $0.0 == key }) {
          guard let merged = relation.children[index].1.merged(with: child) else {
            preconditionFailure(
              "The association key \"\(key)\" is ambiguous. Use the Association.forKey(_:) method is order to disambiguate."
            )
          }
          relation.children.remove(at: index)
          relation.children.append((key, merged))
        } else {
          relation.children.append((key, child))
        }
      }
    }

    /// CTEs of the relation and of its joined children.
    var allCTEs: [(String, SQLCTE)] {
      var result = ctes
      for (_, child) in children where child.kind == .oneOptional || child.kind == .oneRequired {
        for (name, cte) in child.relation.allCTEs {
          if let index = result.firstIndex(where: { $0.0 == name }) {
            result[index].1 = cte
          } else {
            result.append((name, cte))
          }
        }
      }
      return result
    }

    func fetchCount(_ db: Database) throws -> Int {
      guard group == nil && limit == nil && ctes.isEmpty,
        !children.contains(where: { $0.1.impactsParentCount })
      else {
        return try fetchTrivialCount(db)
      }
      let selection = try self.selection.resolve(db)
      if selection.count == 1 {
        guard let count = selection[0].count(distinct: isDistinct) else {
          return try fetchTrivialCount(db)
        }
        var relation = unordered()
        relation.isDistinct = false
        switch count {
        case .all:
          relation = relation.select([.expression(.countAll)])
        case .distinct(let expression):
          relation = relation.select([
            .expression(.aggregate("COUNT", [expression], distinct: true))
          ])
        }
        return try QueryInterfaceRequest<Int>(relation: relation).fetchOne(db) ?? 0
      }
      if isDistinct || selection.contains(where: \.requiresTrivialCount) {
        return try fetchTrivialCount(db)
      }
      let relation = unordered().select([.expression(.countAll)])
      return try QueryInterfaceRequest<Int>(relation: relation).fetchOne(db) ?? 0
    }

    private func fetchTrivialCount(_ db: Database) throws -> Int {
      let request = SQLRequest<Int>(
        literal: "SELECT COUNT(*) FROM (\(SQLSubquery.relation(unordered())))"
      )
      return try request.fetchOne(db) ?? 0
    }
  }

  extension SQLRelation.Child.Kind {
    func merged(with other: Self) -> Self? {
      switch (self, other) {
      case (.oneRequired, .oneRequired), (.oneRequired, .oneOptional), (.oneOptional, .oneRequired):
        return .oneRequired
      case (.oneOptional, .oneOptional): return .oneOptional
      case (.all, .all): return .all
      case (.bridge, .bridge): return .bridge
      default: return nil
      }
    }
  }

  extension SQLAssociationCondition {
    func merged(with other: Self) -> Self? {
      switch (self, other) {
      case (.foreignKey(let lhs), .foreignKey(let rhs)): return lhs == rhs ? self : nil
      case (.expression, .expression): return other
      default: return nil
      }
    }
  }

  extension SQLRelation.Child {
    func merged(with other: SQLRelation.Child) -> SQLRelation.Child? {
      guard let condition = condition.merged(with: other.condition),
        let relation = relation.merged(with: other.relation),
        let kind = kind.merged(with: other.kind)
      else {
        return nil
      }
      return SQLRelation.Child(kind: kind, condition: condition, relation: relation)
    }
  }

  extension SQLSource {
    func merged(with other: SQLSource) -> SQLSource? {
      guard tableName == other.tableName else { return nil }
      switch (alias, other.alias) {
      case (nil, nil): return self
      case (let alias?, nil), (nil, let alias?):
        return SQLSource(tableName: tableName, alias: alias)
      case (let alias?, let otherAlias?):
        guard let merged = alias.merged(with: otherAlias) else { return nil }
        return SQLSource(tableName: tableName, alias: merged)
      }
    }
  }

  extension SQLRelation {
    /// Merges two relations on the same table, as when an association is joined twice.
    func merged(with other: SQLRelation) -> SQLRelation? {
      guard let source = source.merged(with: other.source) else { return nil }
      func and(_ lhs: Deferred<SQLExpression>?, _ rhs: Deferred<SQLExpression>?)
        -> Deferred<SQLExpression>?
      {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?):
          return Deferred { try .associative(.and, [lhs.resolve($0), rhs.resolve($0)]) }
        case (let deferred?, nil), (nil, let deferred?): return deferred
        case (nil, nil): return nil
        }
      }
      var children: [(String, Child)] = []
      for (key, child) in self.children {
        if let otherChild = other.children.first(where: { $0.0 == key })?.1 {
          guard let merged = child.merged(with: otherChild) else { return nil }
          children.append((key, merged))
        } else {
          children.append((key, child))
        }
      }
      for (key, child) in other.children where !children.contains(where: { $0.0 == key }) {
        children.append((key, child))
      }
      let lhsSelection = selection
      let rhsSelection = other.selection
      var ctes = self.ctes
      for (name, cte) in other.ctes {
        if let index = ctes.firstIndex(where: { $0.0 == name }) {
          ctes[index].1 = cte
        } else {
          ctes.append((name, cte))
        }
      }
      return SQLRelation(
        source: source,
        selection: Deferred { db in
          let rhs = try rhsSelection.resolve(db)
          return rhs.isEmpty ? try lhsSelection.resolve(db) : rhs
        },
        filter: and(filter, other.filter),
        ordering: other.ordering.isEmpty ? ordering : other.ordering,
        ctes: ctes,
        children: children,
        isDistinct: isDistinct || other.isDistinct,
        group: other.group ?? group,
        having: and(having, other.having),
        limit: other.limit ?? limit
      )
    }
  }

  // MARK: - Query generation

  /// A relation whose expressions are qualified with table aliases.
  private struct QualifiedRelation {
    var tableName: String
    var alias: TableAliasBase
    var selection: Deferred<[SQLSelection]>
    var filter: Deferred<SQLExpression>?
    var ordering: SQLRelation.Ordering
    var group: Deferred<[SQLExpression]>?
    var having: Deferred<SQLExpression>?
    var joins: [(String, QualifiedJoin)]
    var isDistinct: Bool
    var limit: SQLLimit?
    var ctes: [(String, SQLCTE)]

    init(_ relation: SQLRelation) {
      tableName = relation.source.tableName
      let alias = relation.source.alias ?? TableAliasBase(tableName: relation.source.tableName)
      self.alias = alias
      isDistinct = relation.isDistinct
      limit = relation.limit
      ctes = relation.allCTEs
      joins = relation.children.compactMap { key, child in
        QualifiedJoin(child).map { (key, $0) }
      }
      let ownSelection = relation.selection.map { $0.map { $0.qualified(with: alias) } }
      let joinSelections = joins.map(\.1.relation.allSelection)
      selection = Deferred { db in
        try ownSelection.resolve(db) + joinSelections.flatMap { try $0.resolve(db) }
      }
      sourceSelection = ownSelection
      filter = relation.filter?.map { $0.qualified(with: alias) }
      group = relation.group?.map { $0.map { $0.qualified(with: alias) } }
      having = relation.having?.map { $0.qualified(with: alias) }
      let joinOrderings = joins.map(\.1.relation.allOrdering)
      var ordering = relation.ordering.qualified(with: alias)
      for joinOrdering in joinOrderings where !joinOrdering.isEmpty {
        ordering = ordering.appending(joinOrdering)
      }
      self.ordering = ordering
    }

    var sourceSelection: Deferred<[SQLSelection]>

    /// The selection of this relation and its joins, used when this relation is joined.
    var allSelection: Deferred<[SQLSelection]> { selection }

    var allOrdering: SQLRelation.Ordering { ordering }

    var allAliases: [TableAliasBase] {
      [alias] + joins.flatMap(\.1.relation.allAliases)
    }

    func sourceSQL(_ context: SQLGenerationContext) -> String {
      if let aliasName = context.aliasName(for: alias) {
        return quoted(tableName) + " " + quoted(aliasName)
      }
      return quoted(tableName)
    }

    /// The row adapter that splits joined rows into scopes.
    func rowAdapter(_ context: SQLGenerationContext, from start: Int, root: Bool) throws -> (
      adapter: any RowAdapter, end: Int
    )? {
      if root && joins.isEmpty { return nil }
      let db = try context.requireDatabase()
      let width = try sourceSelection.resolve(db)
        .reduce(0) { total, selection in
          guard let count = try selection.columnCount(context) else {
            throw DatabaseError(
              resultCode: .SQLITE_MISUSE,
              message:
                "Selection literals don't known how many columns they contain. To resolve this error, select one or several expressions instead."
            )
          }
          return total + count
        }
      var end = start + width
      var scopes: [String: any RowAdapter] = [:]
      for (key, join) in joins {
        if let (adapter, joinEnd) = try join.relation.rowAdapter(context, from: end, root: false) {
          scopes[key] = adapter
          end = joinEnd
        }
      }
      if (root || width == 0) && scopes.isEmpty { return nil }
      let range = RangeRowAdapter(start..<(start + width))
      return (range.addingScopes(scopes), end)
    }
  }

  private struct QualifiedJoin {
    enum Kind: String {
      case leftJoin = "LEFT JOIN"
      case innerJoin = "JOIN"
    }

    var kind: Kind
    var condition: SQLAssociationCondition
    var relation: QualifiedRelation

    init?(_ child: SQLRelation.Child) {
      switch child.kind {
      case .oneRequired: kind = .innerJoin
      case .oneOptional: kind = .leftJoin
      case .all, .bridge: return nil
      }
      condition = child.condition
      relation = QualifiedRelation(child.relation)
    }

    func sql(_ context: SQLGenerationContext, left: TableAliasBase, allowsInnerJoin: Bool = true)
      throws -> String
    {
      if kind == .innerJoin && !allowsInnerJoin {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message:
            "Not implemented: chaining a required association behind an optional association"
        )
      }
      let db = try context.requireDatabase()
      var sql = kind.rawValue + " " + relation.sourceSQL(context)
      var conditions: [SQLExpression] = []
      if let expression = try condition.joinExpression(db, left: left, right: relation.alias) {
        conditions.append(expression)
      }
      if let filter = try relation.filter?.resolve(db) {
        conditions.append(filter)
      }
      if !conditions.isEmpty {
        sql += try " ON " + SQLExpression.associative(.and, conditions).sql(context)
      }
      for (_, join) in relation.joins {
        sql +=
          try " "
          + join.sql(
            context,
            left: relation.alias,
            allowsInnerJoin: allowsInnerJoin && kind == .innerJoin
          )
      }
      return sql
    }
  }

  /// Generates SELECT, UPDATE, and DELETE statements from relations.
  struct SQLQueryGenerator {
    private let relation: QualifiedRelation
    private let singleResult: Bool

    init(relation: SQLRelation, forSingleResult singleResult: Bool = false) {
      self.relation = QualifiedRelation(relation)
      self.singleResult = singleResult
    }

    func requestSQL(_ context: SQLGenerationContext) throws -> String {
      let context = context.subqueryContext(aliases: relation.allAliases, ctes: relation.ctes)
      let db = try context.requireDatabase()
      var sql = try commonTableExpressionsPrefix(context)
      sql += relation.isDistinct ? "SELECT DISTINCT " : "SELECT "
      let selection = try relation.selection.resolve(db)
      guard !selection.isEmpty else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "Can't generate SQL with an empty selection"
        )
      }
      sql += try selection.map { try $0.sql(context) }.joined(separator: ", ")
      sql += " FROM " + relation.sourceSQL(context)
      for (_, join) in relation.joins {
        sql += try " " + join.sql(context, left: relation.alias)
      }
      let filter = try relation.filter?.resolve(db)
      if let filter {
        sql += try " WHERE " + filter.sql(context)
      }
      let groups = try relation.group?.resolve(db) ?? []
      if !groups.isEmpty {
        sql += try " GROUP BY " + groups.map { try $0.sql(context) }.joined(separator: ", ")
      }
      if let having = try relation.having?.resolve(db) {
        sql += try " HAVING " + having.sql(context)
      }
      let orderings = try relation.ordering.resolve(db)
      if !orderings.isEmpty {
        sql += try " ORDER BY " + orderings.map { try $0.sql(context) }.joined(separator: ", ")
      }
      var limit = relation.limit
      if limit == nil, singleResult,
        try !expectsSingleResult(db, selection: selection, filter: filter, groups: groups)
      {
        limit = SQLLimit(limit: 1)
      }
      if let limit {
        sql += " LIMIT " + limit.sql
      }
      return sql
    }

    private func expectsSingleResult(
      _ db: Database,
      selection: [SQLSelection],
      filter: SQLExpression?,
      groups: [SQLExpression]
    ) throws -> Bool {
      if !relation.joins.isEmpty { return false }
      if let filter, try db.tableExists(relation.tableName) {
        let columns = try filter.identifyingColumns(db, for: relation.alias)
        if try db.table(relation.tableName, hasUniqueKey: columns) {
          return true
        }
      }
      return groups.isEmpty && selection.contains(where: \.isAggregate)
    }

    func makeStatement(_ db: Database) throws -> Statement {
      let context = SQLGenerationContext(db)
      let sql = try requestSQL(context)
      let statement = try db.makeStatement(sql: sql)
      statement.arguments = context.arguments
      // Provably empty requests on tables, such as `Player.none()`, observe nothing.
      if let filter = try relation.filter?.resolve(db), filter.selectsNoRow,
        try db.tableExists(relation.tableName)
      {
        statement.databaseRegion = DatabaseRegion()
      }
      return statement
    }

    func makePreparedRequest(_ db: Database) throws -> PreparedRequest {
      let statement = try makeStatement(db)
      return PreparedRequest(statement: statement, adapter: try rowAdapter(db))
    }

    func rowAdapter(_ db: Database) throws -> (any RowAdapter)? {
      let context = SQLGenerationContext(db, ctes: relation.ctes)
      return try relation.rowAdapter(context, from: 0, root: true)?.adapter
    }

    func columnCount(_ db: Database) throws -> Int {
      let context = SQLGenerationContext(db, ctes: relation.ctes)
      return try relation.selection.resolve(db)
        .reduce(0) { total, selection in
          guard let count = try selection.columnCount(context) else {
            throw DatabaseError(
              resultCode: .SQLITE_MISUSE,
              message:
                "Selection literals don't known how many columns they contain. To resolve this error, select one or several expressions instead."
            )
          }
          return total + count
        }
    }

    private func commonTableExpressionsPrefix(_ context: SQLGenerationContext) throws -> String {
      if relation.ctes.isEmpty { return "" }
      var sql = "WITH "
      if relation.ctes.contains(where: { $0.1.isRecursive }) {
        sql += "RECURSIVE "
      }
      sql += try relation.ctes
        .map { name, cte in
          var columns = ""
          if let names = cte.columns, !names.isEmpty {
            columns = "(" + names.map(quoted).joined(separator: ", ") + ")"
          }
          return try quoted(name) + columns + " AS ("
            + cte.subquery.sql(context.subqueryContext()) + ")"
        }
        .joined(separator: ", ")
      return sql + " "
    }

    // MARK: Mutations

    private enum Grouping {
      case none, unique, nonUnique
    }

    private func grouping(_ db: Database) throws -> (Grouping, SQLQueryGenerator) {
      guard let groups = try relation.group?.resolve(db), !groups.isEmpty else {
        return (.none, self)
      }
      // Resolve the grouping once: the key subquery reuses the resolved expressions.
      var resolved = relation
      resolved.group = Deferred(value: groups)
      let generator = SQLQueryGenerator(qualified: resolved)
      guard try db.tableExists(relation.tableName) else { return (.nonUnique, generator) }
      var columns: Set<String> = []
      for expression in groups {
        guard let column = try expression.column(db, for: relation.alias, acceptsBijection: true)
        else {
          return (.nonUnique, generator)
        }
        columns.insert(column)
      }
      let unique = try db.table(relation.tableName, hasUniqueKey: columns)
      return (unique ? .unique : .nonUnique, generator)
    }

    private func groupingMisuse(_ action: String) -> DatabaseError {
      DatabaseError(
        resultCode: .SQLITE_MISUSE,
        message: "Can't \(action) query with GROUP BY clause"
      )
    }

    func makeDeleteStatement(_ db: Database, selection: [any SQLSelectable] = []) throws
      -> Statement
    {
      let (grouping, generator) = try grouping(db)
      switch grouping {
      case .none:
        guard relation.joins.isEmpty else {
          return try makeTrivialStatement(
            db,
            prefix: "DELETE FROM",
            set: nil,
            selection: selection
          )!
        }
        let context = SQLGenerationContext(db, aliases: relation.allAliases, ctes: relation.ctes)
        var sql = try commonTableExpressionsPrefix(context)
        sql += "DELETE FROM " + relation.sourceSQL(context)
        sql += try conditionSQL(context, db: db)
        return try makeStatement(db, sql: sql, context: context, returning: selection)
      case .unique:
        return try generator.makeTrivialStatement(
          db,
          prefix: "DELETE FROM",
          set: nil,
          selection: selection
        )!
      case .nonUnique:
        throw groupingMisuse("delete")
      }
    }

    func makeUpdateStatement(
      _ db: Database,
      conflict: Database.ConflictResolution,
      assignments: [ColumnAssignment],
      selection: [any SQLSelectable] = []
    ) throws -> Statement? {
      let prefix = conflict == .abort ? "UPDATE" : "UPDATE OR " + conflict.sqlName
      let (grouping, generator) = try grouping(db)
      switch grouping {
      case .none:
        guard relation.joins.isEmpty else {
          return try makeTrivialStatement(
            db,
            prefix: prefix,
            set: assignments,
            selection: selection
          )
        }
        let context = SQLGenerationContext(db, aliases: relation.allAliases, ctes: relation.ctes)
        var sql = try commonTableExpressionsPrefix(context)
        sql += prefix + " " + relation.sourceSQL(context)
        let updates = try assignments.compactMap { try $0.sql(context) }
        if updates.isEmpty { return nil }
        sql += " SET " + updates.joined(separator: ", ")
        sql += try conditionSQL(context, db: db)
        return try makeStatement(db, sql: sql, context: context, returning: selection)
      case .unique:
        return try generator.makeTrivialStatement(
          db,
          prefix: prefix,
          set: assignments,
          selection: selection
        )
      case .nonUnique:
        throw groupingMisuse("update")
      }
    }

    private func conditionSQL(_ context: SQLGenerationContext, db: Database) throws -> String {
      var sql = ""
      if let filter = try relation.filter?.resolve(db) {
        sql += try " WHERE " + filter.sql(context)
      }
      if let limit = relation.limit {
        let orderings = try relation.ordering.resolve(db)
        if !orderings.isEmpty {
          sql += try " ORDER BY " + orderings.map { try $0.sql(context) }.joined(separator: ", ")
        }
        sql += " LIMIT " + limit.sql
      }
      return sql
    }

    /// `UPDATE/DELETE ... WHERE key IN (SELECT key FROM ...)`, for joined or grouped requests.
    private func makeTrivialStatement(
      _ db: Database,
      prefix: String,
      set assignments: [ColumnAssignment]?,
      selection: [any SQLSelectable]
    ) throws -> Statement? {
      let alias = TableAliasBase(tableName: relation.tableName)
      let context = SQLGenerationContext(db, aliases: [alias])
      var sql = prefix + " " + quoted(relation.tableName)
      if let assignments {
        let updates = try assignments.compactMap { try $0.sql(context) }
        if updates.isEmpty { return nil }
        sql += " SET " + updates.joined(separator: ", ")
      }
      let key = try keyExpression(db)
      sql += try " WHERE " + key.qualified(with: alias).sql(context) + " IN ("
      var keyRelation = relation
      let keySelection: [SQLSelection]
      if case .row(let columns) = key.node {
        keySelection = columns.map { .expression($0.qualified(with: relation.alias)) }
      } else {
        keySelection = [.expression(key.qualified(with: relation.alias))]
      }
      keyRelation.selection = Deferred(value: keySelection)
      keyRelation.isDistinct = false
      keyRelation.joins = keyRelation.joins.map { ($0.0, $0.1.selectingNothing()) }
      let subcontext = context.subqueryContext(aliases: relation.allAliases, ctes: relation.ctes)
      sql += try SQLQueryGenerator(qualified: keyRelation).requestSQL(subcontext)
      sql += ")"
      return try makeStatement(db, sql: sql, context: context, returning: selection)
    }

    private func keyExpression(_ db: Database) throws -> SQLExpression {
      let key = try db.primaryKey(relation.tableName)
      if try key.rowIDColumn != nil || key.columns.count == 1
        || db.tableHasRowID(relation.tableName)
      {
        return .fastPrimaryKey
      }
      // WITHOUT ROWID tables with a composite primary key: compare row values.
      return .rowValue(key.columns.map { SQLExpression.column($0) })!
    }

    private init(qualified: QualifiedRelation) {
      relation = qualified
      singleResult = false
    }

    /// Appends a RETURNING clause, qualifying the selection with the mutated table.
    private func makeStatement(
      _ db: Database,
      sql: String,
      context: SQLGenerationContext,
      returning selection: [any SQLSelectable]
    ) throws -> Statement {
      var sql = sql
      var arguments = context.arguments
      if !selection.isEmpty {
        let alias = TableAliasBase(tableName: relation.tableName)
        let returningContext = SQLGenerationContext(db, aliases: [alias])
        sql +=
          try " RETURNING "
          + selection.map { try $0.sqlSelection.qualified(with: alias).sql(returningContext) }
          .joined(separator: ", ")
        arguments = arguments &+ returningContext.arguments
      }
      let statement = try db.makeStatement(sql: sql)
      statement.arguments = arguments
      return statement
    }
  }

  extension QualifiedJoin {
    fileprivate func selectingNothing() -> QualifiedJoin {
      var result = self
      result.relation.selection = Deferred(value: [])
      result.relation.sourceSelection = Deferred(value: [])
      result.relation.joins = result.relation.joins.map { ($0.0, $0.1.selectingNothing()) }
      return result
    }
  }

  extension Database.ConflictResolution {
    var sqlName: String { rawValue.uppercased() }
  }
#endif
