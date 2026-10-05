import SQLiteOrbit
import Testing

@Suite
struct OrbitFetchSectionCollectionTests {
  @Test(arguments: [
    (keys: [Int?](), sections: [[Int]]()),
    (keys: [nil], sections: [[0]]),
    (keys: [2, 2, 1, 1], sections: [[0, 1], [2, 3]]),
    (keys: [2, 2, 1, 2, 2], sections: [[0, 1, 3, 4], [2]]),
    (keys: [nil, 2, nil, 1, 2, nil], sections: [[0, 2, 5], [1, 4], [3]])
  ])
  func groupingPreservesBothFlatAndSectionOrder(keys: [Int?], sections expected: [[Int]]) {
    let elements = keys.indices.map { Item(id: $0, group: keys[$0]) }
    var visited: [Int] = []
    let sections = OrbitFetchSectionCollection(grouping: elements) { element in
      visited.append(element.id)
      return element.group
    }
    #expect(visited == Array(keys.indices))
    #expect(sections.elements == elements)
    #expect(sections.map { $0.map(\.id) } == expected)
    #expect(sections.sectionNames == expected.map { keys[$0[0]] })
    for (position, indices) in expected.enumerated() {
      let name = keys[indices[0]]
      #expect(sections.contains(sectionName: name))
      #expect(sections.index(ofSectionNamed: name) == position)
      #expect(sections[sectionName: name]?.map(\.id) == indices)
      #expect(sections[position].id == name)
    }
    #expect(!sections.contains(sectionName: -1))
    #expect(sections.index(ofSectionNamed: -1) == nil)
    #expect(sections[sectionName: -1] == nil)
  }

  @Test
  func aThrowingGroupingStopsAtTheFailingElement() {
    var visited: [Int] = []
    #expect(throws: GroupingError.failed) {
      _ = try OrbitFetchSectionCollection(grouping: [1, 2, 3]) { value in
        visited.append(value)
        if value == 2 { throw GroupingError.failed }
        return value
      }
    }
    #expect(visited == [1, 2])
  }

  private struct Item: Equatable {
    let id: Int
    let group: Int?
  }

  private enum GroupingError: Error {
    case failed
  }
}
