#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // Prefetching of to-many associations (`including(all:)`): after the base rows are fetched,
  // one request per prefetched association loads the associated rows, and groups them by the
  // values of their pivot columns.

  extension SQLRelation.Child {
    func makeAssociation(forKey key: String) -> _SQLAssociation {
      _SQLAssociation(
        key: .fixed(key),
        condition: condition,
        relation: relation,
        cardinality: kind == .oneOptional || kind == .oneRequired ? .toOne : .toMany
      )
    }
  }

  extension SQLRelation {
    /// Appends the primary key (or all columns) to the ordering, here and in joined relations.
    func withStableOrder() -> SQLRelation {
      let table = source.tableName
      let current = self
      return with { relation in
        let stable = SQLRelation.Ordering(
          Deferred { db in
            if let columns = try? db.primaryKey(table).columns {
              return columns.map { SQLExpression.column($0).sqlOrdering }
            }
            let count = try SQLQueryGenerator(relation: current).columnCount(db)
            return (1...count).map { SQL(sql: "\($0)").sqlOrdering }
          }
        )
        relation.ordering = relation.ordering.appending(stable)
        relation.children = relation.children.map { key, child in
          var child = child
          child.relation = child.relation.withStableOrder()
          return (key, child)
        }
      }
    }

    func removingChild(forKey key: String) -> SQLRelation {
      with { $0.children.removeAll { $0.0 == key } }
    }

    /// The prefetched associations, from the relation (possibly through joined to-one
    /// associations).
    var prefetchedAssociations: [_SQLAssociation] {
      children.flatMap { key, child -> [_SQLAssociation] in
        switch child.kind {
        case .all:
          return [child.makeAssociation(forKey: key)]
        case .oneOptional, .oneRequired, .bridge:
          return child.relation.prefetchedAssociations.map { association in
            var pivot = child
            pivot.relation = pivot.relation.removingChild(forKey: association.pivot.keyName)
            return association.through(pivot.makeAssociation(forKey: key))
          }
        }
      }
    }
  }

  /// Loads prefetched associations into `rows`, fetched from `origin`.
  func prefetch(
    _ db: Database,
    associations: [_SQLAssociation],
    from origin: SQLRelation,
    into rows: [Row],
    willExecute: WillExecuteSupplementaryRequest? = nil
  ) throws {
    guard let firstRow = rows.first else { return }
    for association in associations {
      guard case .foreignKey(let foreignKey) = association.pivot.condition else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "Not implemented: prefetch association without any foreign key"
        )
      }
      let mapping = try foreignKey.joinMapping(db, from: origin.source.tableName)
      let pivotColumns = mapping.rightColumns
      let leftIndexes = try mapping.leftColumns.map { column -> Int in
        guard let index = firstRow.index(ofColumn: column) else {
          throw DatabaseError(
            resultCode: .SQLITE_MISUSE,
            message: "Column \(column) is not selected"
          )
        }
        return index
      }
      func leftValues(_ row: Row) -> [DatabaseValue] {
        let values = row.databaseValues
        return leftIndexes.map { values[$0] }
      }

      let request: QueryInterfaceRequest<Row>
      if mapping.pairs.count > 1 {
        // Avoid huge expressions for composite keys: inject the base request as a CTE.
        //   WITH grdb_base AS (SELECT a, b FROM parent)
        //   SELECT * FROM child WHERE (a, b) IN grdb_base
        let base =
          origin
          .unorderedUnlessLimited()
          .removingPrefetchedAssociations()
          .selectOnly(mapping.leftColumns.map { .expression(.column($0)) })
        let cte = CommonTableExpression<Row>(
          named: "grdb_base",
          request: QueryInterfaceRequest<Row>(relation: base)
        )
        let filter = cte.contains(SQLExpression.rowValue(pivotColumns.map { .column($0) })!)
        request = prefetchRequest(association, filter: filter, pivotColumns: pivotColumns)
          .with(cte)
      } else {
        // SELECT *, authorId AS grdb_authorId FROM book WHERE authorId IN (1, 2, 3)
        let column = mapping.leftColumns[0].lowercased()
        let filter = mapping.joinExpression(
          leftValues: rows.map { [column: leftValues($0)[0]] }
        )
        request = prefetchRequest(association, filter: filter, pivotColumns: pivotColumns)
      }

      try willExecute?(request, association.keyPath)
      let prefetched = try request.fetchAll(db)
      var groups: [[DatabaseValue]: [Row]] = [:]
      if let first = prefetched.first {
        let indexes = try pivotColumns.map { column -> Int in
          guard let index = first.index(ofColumn: "grdb_" + column) else {
            throw DatabaseError(
              resultCode: .SQLITE_MISUSE,
              message: "Column grdb_\(column) is not selected"
            )
          }
          return index
        }
        for row in prefetched {
          let values = row.databaseValues
          groups[indexes.map { values[$0] }, default: []].append(row)
        }
      }
      for row in rows {
        row.prefetchedRows.setRows(groups[leftValues(row)] ?? [], forKeyPath: association.keyPath)
      }
    }
  }

  /// The request for the rows of a prefetched association, annotated with the pivot columns
  /// (`grdb_<column>`) so that they can be grouped by base row.
  func prefetchRequest(
    _ association: _SQLAssociation,
    filter: SQLExpression,
    pivotColumns: [String]
  ) -> QueryInterfaceRequest<Row> {
    let pivotAlias = TableAliasBase()
    var association = association
    association.pivot.relation = association.pivot.relation.aliased(pivotAlias).filter(filter)
    let annotations = pivotColumns.map {
      SQLSelection.aliasedExpression(.qualifiedColumn($0, pivotAlias), "grdb_" + $0)
    }
    let relation = association.destinationRelation().annotatedWhenConnected { _ in annotations }
    return QueryInterfaceRequest(relation: relation)
  }
#endif

#if canImport(Foundation) && canImport(Dispatch)
  extension SQLRelation {
    /// The region read by the requests of prefetched associations, so that observations of
    /// requests with `including(all:)` track associated tables before any row is fetched.
    func prefetchedRegion(_ db: Database) throws -> DatabaseRegion {
      var region = DatabaseRegion()
      for association in prefetchedAssociations {
        guard case .foreignKey(let foreignKey) = association.pivot.condition else { continue }
        let mapping = try foreignKey.joinMapping(db, from: source.tableName)
        // Filter on a dummy value so that all join columns are part of the region.
        let filter = mapping.joinExpression(
          leftValues: [
            Dictionary(
              mapping.leftColumns.map { ($0.lowercased(), 1.databaseValue) },
              uniquingKeysWith: { lhs, _ in lhs }
            )
          ]
        )
        let request = prefetchRequest(
          association,
          filter: filter,
          pivotColumns: mapping.rightColumns
        )
        let statement = try SQLQueryGenerator(relation: request.relation).makeStatement(db)
        guard !statement.databaseRegion.isEmpty else { continue }
        region = try region.union(statement.databaseRegion)
          .union(request.relation.prefetchedRegion(db))
      }
      return region
    }
  }

  extension QueryInterfaceRequest {
    /// The region of the requests of prefetched associations (`including(all:)`).
    func prefetchedRegion(_ db: Database) throws -> DatabaseRegion {
      if let filter = try relation.filter?.resolve(db), filter.selectsNoRow,
        try db.tableExists(relation.source.tableName)
      {
        return DatabaseRegion()
      }
      return try relation.prefetchedRegion(db)
    }
  }
#endif
