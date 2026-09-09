// The sectioned form of `@FetchAll`'s read. The database does the grouping: the section
// expression is selected alongside the row and ordered ahead of the statement's own ordering, so
// one pass over the result set both decodes the rows and lays out the sections.

/// A statement selecting every column of a table, then the section expression, ordered by it.
func orbitSectionedColumns<From: Table, Key: QueryRepresentable>(
  of _: From.Type,
  _ sectionBy: _OrbitFetchSectioning<Key>
) -> Select<(From, Key), From, ()> {
  From.unscoped
    .select { ($0, SQLQueryExpression(sectionBy.select, as: Key.self)) }
    .order { _ in SQLQueryExpression(sectionBy.order) }
}

/// A statement selecting the section expression alone.
func orbitSectionedColumn<From: Table, Key: QueryRepresentable>(
  of _: From.Type,
  _ sectionBy: _OrbitFetchSectioning<Key>
) -> Select<Key, From, ()> {
  From.unscoped.asSelect()
    .select { _ in SQLQueryExpression(sectionBy.select, as: Key.self) }
}

/// A statement ordering by the section expression alone.
func orbitSectionedOrder<From: Table, Key>(
  of _: From.Type,
  _ sectionBy: _OrbitFetchSectioning<Key>
) -> Select<(), From, ()> {
  From.unscoped.asSelect()
    .order { _ in SQLQueryExpression(sectionBy.order) }
}

struct OrbitFetchSectionedStatementRequest<Value: QueryRepresentable, Key: QueryRepresentable>:
  OrbitFetchKeyRequest
where Value.QueryOutput: Sendable, Key.QueryOutput: Hashable & Sendable {
  let query: QueryFragment

  func fetch(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws -> OrbitFetchSectionCollection<Value.QueryOutput, Key.QueryOutput> {
    var elements: [Value.QueryOutput] = []
    var sections: [(name: Key.QueryOutput, elements: OrbitFetchElementIndices)] = []
    var positionsByName: [Key.QueryOutput: Int] = [:]
    var cursor = try transaction.rowCursor(
      SQLQueryExpression<Void>(query, as: Void.self),
      cached: true
    )
    while var row = try cursor.next() {
      let element = try row.decode(Value.self)
      let name = try row.decode(Key.self)
      let index = elements.count
      if let position = positionsByName[name] {
        sections[position].elements.append(index)
      } else {
        positionsByName[name] = sections.count
        sections.append((name, OrbitFetchElementIndices(range: index..<(index + 1))))
      }
      elements.append(element)
    }
    return OrbitFetchSectionCollection(elements: elements, sections: sections)
  }
}
