extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Decodes and groups every row returned by raw SQL, without changing the query's ordering.
  ///
  /// Sections follow the first appearance of each decoded key, using its `Hashable` equality.
  /// Both the flat elements and each section retain query order, including nonadjacent members.
  /// Empty results produce no sections; an optional key of `nil` names an ordinary section.
  ///
  /// - Parameters:
  ///   - sql: The query to execute, which must only read in a read transaction.
  ///   - transform: Decodes an element and its section key from a row, valid only during the call.
  /// - Throws: Any statement or decoding error.
  public borrowing func fetchSections<Element, Key: Hashable>(
    _ sql: SQL,
    _ transform: (inout Row) throws -> (element: Element, key: Key)
  ) throws -> OrbitFetchSectionCollection<Element, Key> {
    try withOrbitCursor(try rowCursor(sql, cached: true)) { cursor in
      var elements: [Element] = []
      var sections: [(name: Key, elements: OrbitFetchElementIndices)] = []
      var positionsByName: [Key: Int] = [:]
      while var row = try cursor.next() {
        let (element, name) = try transform(&row)
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
}
