/// The rows a ``FetchAll`` property observes, grouped into sections.
///
/// You do not create this collection. A property built with a `sectionBy:` expression groups its
/// rows into one section per distinct value of that expression, and projects them here:
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
/// The grouping is the database's: the expression is evaluated by it, ordered by it, and its value
/// as text names each section. A property with no `sectionBy:` expression still projects one, whose
/// single section is named `nil` and holds every row.
public struct OrbitFetchSectionCollection<Element, SectionName: Hashable> {
  /// Every row, in the order the query produced them.
  public let elements: [Element]

  private let sections: [(name: SectionName, elements: OrbitFetchElementIndices)]
  private let positionsByName: [SectionName: Int]

  /// Creates an empty collection.
  public init() {
    self.elements = []
    self.sections = []
    self.positionsByName = [:]
  }

  /// Creates a collection of one section holding every element.
  ///
  /// - Parameters:
  ///   - elements: The rows the section holds.
  ///   - sectionName: The name of the section.
  public init(elements: [Element], sectionName: SectionName) {
    self.elements = elements
    if elements.isEmpty {
      self.sections = []
      self.positionsByName = [:]
    } else {
      self.sections = [
        (sectionName, OrbitFetchElementIndices(range: elements.indices))
      ]
      self.positionsByName = [sectionName: 0]
    }
  }

  init(
    elements: [Element],
    sections: [(name: SectionName, elements: OrbitFetchElementIndices)]
  ) {
    self.elements = elements
    self.sections = sections
    self.positionsByName = Dictionary(
      uniqueKeysWithValues: sections.enumerated().map { ($0.element.name, $0.offset) }
    )
  }

  /// The name of each section, in the order the sections appear.
  public var sectionNames: [SectionName] {
    sections.map(\.name)
  }

  /// Returns the section with the given name, or `nil` when there is none.
  ///
  /// - Parameter name: The name of a section.
  public subscript(sectionName name: SectionName) -> OrbitFetchSection<Element, SectionName>? {
    guard let position = positionsByName[name] else { return nil }
    return self[position]
  }

  /// Returns whether the collection holds a section with the given name.
  ///
  /// - Parameter name: The name of a section.
  public func contains(sectionName name: SectionName) -> Bool {
    positionsByName[name] != nil
  }

  /// Returns the position of the section with the given name, or `nil` when there is none.
  ///
  /// - Parameter name: The name of a section.
  public func index(ofSectionNamed name: SectionName) -> Int? {
    positionsByName[name]
  }
}

extension OrbitFetchSectionCollection: RandomAccessCollection {
  /// The position of the first section.
  public var startIndex: Int { sections.startIndex }

  /// The position one past the last section.
  public var endIndex: Int { sections.endIndex }

  /// Returns the section at a position.
  ///
  /// - Parameter position: The position of a section.
  public subscript(position: Int) -> OrbitFetchSection<Element, SectionName> {
    let section = sections[position]
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

/// One section of the rows a ``FetchAll`` property observes.
///
/// See ``OrbitFetchSectionCollection`` for more.
public struct OrbitFetchSection<Element, SectionName: Hashable>: Identifiable {
  /// The name of the section, which is the value of the `sectionBy:` expression its rows share.
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
