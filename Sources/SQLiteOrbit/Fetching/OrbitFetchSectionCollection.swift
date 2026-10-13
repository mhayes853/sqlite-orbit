/// An ordered collection of elements grouped by a hashable section name.
///
/// Group values independently of a database with ``init(grouping:by:)``:
///
/// ```swift
/// let sections = OrbitFetchSectionCollection(grouping: reminders, by: \.priority)
/// ```
///
/// A ``FetchAll`` property built with a `sectionBy:` expression also projects this collection:
///
/// ```swift
/// @FetchAll(Reminder.order(by: \.title), sectionBy: \.priority) var reminders
///
/// var body: some View {
///   List {
///     ForEach($reminders.sections) { section in
///       Section(section.name ?? "None") {
///         ForEach(section, id: \.id) { reminder in Text(reminder.title) }
///       }
///     }
///   }
/// }
/// ```
///
/// With `FetchAll`, the database evaluates and orders the section expression, whose decoded value
/// names each section. A property with no `sectionBy:` expression still projects one section named
/// `nil` holding every row, or no sections when there are no rows.
public struct OrbitFetchSectionCollection<Element, SectionName: Hashable> {
  /// Every element, in its original input or query order.
  public let elements: [Element]

  private let index: OrbitFetchSectionIndex<SectionName>

  /// Creates an empty collection.
  public init() {
    self.init(elements: [], index: OrbitFetchSectionIndex())
  }

  /// Creates a collection of one section holding every element.
  ///
  /// - Parameters:
  ///   - elements: The rows the section holds.
  ///   - sectionName: The name of the section.
  public init(elements: [Element], sectionName: SectionName) {
    self.init(
      elements: elements,
      index: elements.isEmpty
        ? OrbitFetchSectionIndex()
        : OrbitFetchSectionIndex(
          sections: [(sectionName, OrbitFetchElementIndices(range: elements.indices))],
          positionsByName: [sectionName: 0]
        )
    )
  }

  /// Groups elements into one section per distinct name, using the name's `Hashable` equality.
  ///
  /// Sections appear in the order their names first occur. Each section preserves its elements'
  /// input order, even when they are not adjacent, and ``elements`` retains the entire input order.
  /// Empty input produces no sections. An optional name of `nil` is an ordinary section name.
  ///
  /// - Parameters:
  ///   - elements: The elements to group.
  ///   - sectionName: Returns an element's section name, called once per element in input order.
  /// - Throws: Any error thrown by `sectionName`, stopping at that element.
  public init(
    grouping elements: [Element],
    by sectionName: (Element) throws -> SectionName
  ) rethrows {
    var index = OrbitFetchSectionIndex<SectionName>()
    for (offset, element) in elements.enumerated() {
      index.append(offset, to: try sectionName(element))
    }
    self.init(elements: elements, index: index)
  }

  init(elements: [Element], index: OrbitFetchSectionIndex<SectionName>) {
    self.elements = elements
    self.index = index
  }

  /// The name of each section, in the order the sections appear.
  public var sectionNames: [SectionName] {
    index.sections.map(\.name)
  }

  /// Returns the section with the given name, or `nil` when there is none.
  ///
  /// - Parameter name: The name of a section.
  public subscript(sectionName name: SectionName) -> OrbitFetchSection<Element, SectionName>? {
    guard let position = index.positionsByName[name] else { return nil }
    return self[position]
  }

  /// Returns whether the collection holds a section with the given name.
  ///
  /// - Parameter name: The name of a section.
  public func contains(sectionName name: SectionName) -> Bool {
    index.positionsByName[name] != nil
  }

  /// Returns the position of the section with the given name, or `nil` when there is none.
  ///
  /// - Parameter name: The name of a section.
  public func index(ofSectionNamed name: SectionName) -> Int? {
    index.positionsByName[name]
  }
}

extension OrbitFetchSectionCollection: RandomAccessCollection {
  /// The position of the first section.
  public var startIndex: Int { index.sections.startIndex }

  /// The position one past the last section.
  public var endIndex: Int { index.sections.endIndex }

  /// Returns the section at a position.
  ///
  /// - Parameter position: The position of a section.
  public subscript(position: Int) -> OrbitFetchSection<Element, SectionName> {
    let section = index.sections[position]
    return OrbitFetchSection(
      name: section.name,
      base: elements,
      elementIndices: section.elements
    )
  }
}

extension OrbitFetchSectionCollection: Sendable
where Element: Sendable, SectionName: Sendable {}

extension OrbitFetchSectionCollection: Equatable where Element: Equatable {
  /// Returns whether two collections hold the same sections of the same rows.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.elementsEqual(rhs)
  }
}

/// One named section of an ``OrbitFetchSectionCollection``.
///
/// See ``OrbitFetchSectionCollection`` for more.
public struct OrbitFetchSection<Element, SectionName: Hashable>: Identifiable {
  /// The name shared by the elements in this section.
  public let name: SectionName

  private let base: [Element]
  private let elementIndices: OrbitFetchElementIndices

  init(name: SectionName, base: [Element], elementIndices: OrbitFetchElementIndices) {
    self.name = name
    self.base = base
    self.elementIndices = elementIndices
  }

  /// The identity of the section, which is its ``name``.
  public var id: SectionName { name }
}

extension OrbitFetchSection: RandomAccessCollection {
  /// The position of the first row.
  public var startIndex: Int { 0 }

  /// The position one past the last row.
  public var endIndex: Int { elementIndices.count }

  /// Returns the row at a position.
  ///
  /// - Parameter position: The position of a row.
  public subscript(position: Int) -> Element {
    base[elementIndices[position]]
  }
}

extension OrbitFetchSection: Sendable where Element: Sendable, SectionName: Sendable {}

extension OrbitFetchSection: Equatable where Element: Equatable {
  /// Returns whether two sections have the same name and hold the same rows.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.elementsEqual(rhs)
  }
}

/// Builds and retains the section layout and its name lookup in one pass.
struct OrbitFetchSectionIndex<Name: Hashable> {
  var sections: [(name: Name, elements: OrbitFetchElementIndices)] = []
  var positionsByName: [Name: Int] = [:]

  mutating func append(_ elementIndex: Int, to name: Name) {
    if let position = positionsByName[name] {
      sections[position].elements.append(elementIndex)
    } else {
      positionsByName[name] = sections.count
      sections.append((name, OrbitFetchElementIndices(range: elementIndex..<(elementIndex + 1))))
    }
  }
}

extension OrbitFetchSectionIndex: Sendable where Name: Sendable {}

/// Where one section's rows sit in the flat array of every row.
///
/// A query ordered by its section expression puts each section's rows in one run, which is the
/// range. One that is not can return to a section it has already left, and those rows land in the
/// overflow.
struct OrbitFetchElementIndices: Sendable {
  var range: Range<Int>
  var overflow: [Int] = []

  var count: Int {
    range.count + overflow.count
  }

  subscript(position: Int) -> Int {
    position < range.count
      ? range.lowerBound + position
      : overflow[position - range.count]
  }

  mutating func append(_ index: Int) {
    if index == range.upperBound {
      range = range.lowerBound..<(index + 1)
    } else {
      overflow.append(index)
    }
  }
}
