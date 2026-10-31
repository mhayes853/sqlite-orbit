// swift-format-ignore-file: ReplaceForEachWithForLoop

// Cursor is not a Sequence; custom forEach implementations must remain in use.
#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// A type that supplies the values of a sequence, one at a time, and may throw.
  public protocol Cursor<Element>: AnyObject {
    associatedtype Element

    func next() throws -> Element?

    func forEach(_ body: (Element) throws -> Void) throws
  }

  /// A type-erased cursor.
  public final class AnyCursor<Element>: Cursor {
    private let advance: () throws -> Element?
    private let visit: (((Element) throws -> Void) throws -> Void)?

    public init<C: Cursor>(_ cursor: C) where C.Element == Element {
      advance = cursor.next
      visit = cursor.forEach
    }

    public init(_ advance: @escaping () throws -> Element?) {
      self.advance = advance
      visit = nil
    }

    init(
      _ advance: @escaping () throws -> Element?,
      forEach visit: @escaping ((Element) throws -> Void) throws -> Void
    ) {
      self.advance = advance
      self.visit = visit
    }

    public convenience init<S: Sequence>(_ sequence: S) where S.Element == Element {
      self.init(iterator: sequence.makeIterator())
    }

    public convenience init<I: IteratorProtocol>(iterator: I) where I.Element == Element {
      var iterator = iterator
      self.init { iterator.next() }
    }

    public func forEach(_ body: (Element) throws -> Void) throws {
      if let visit {
        try visit(body)
      } else {
        while let value = try advance() {
          try body(value)
        }
      }
    }

    public func next() throws -> Element? {
      try advance()
    }
  }

  extension AnyCursor: @unchecked Sendable {}

  /// A cursor of the rows or values of a database statement.
  ///
  /// In the overlay, record and value cursors are type-erased cursors, so they conform as well.
  public protocol DatabaseCursor<Element>: Cursor {}

  extension AnyCursor: DatabaseCursor {}

  extension RowCursor: DatabaseCursor {}

  /// A cursor of transformed elements.
  public final class MapCursor<Base: Cursor, Element>: Cursor {
    private let base: Base
    private let transform: (Base.Element) throws -> Element

    init(_ base: Base, _ transform: @escaping (Base.Element) throws -> Element) {
      self.base = base
      self.transform = transform
    }

    public func next() throws -> Element? {
      try base.next().map(transform)
    }

    public func forEach(_ body: (Element) throws -> Void) throws {
      try base.forEach { try body(transform($0)) }
    }
  }

  /// A cursor of the elements that satisfy a predicate.
  public final class FilterCursor<Base: Cursor>: Cursor {
    private let base: Base
    private let isIncluded: (Base.Element) throws -> Bool

    init(_ base: Base, _ isIncluded: @escaping (Base.Element) throws -> Bool) {
      self.base = base
      self.isIncluded = isIncluded
    }

    public func next() throws -> Base.Element? {
      while let element = try base.next() {
        if try isIncluded(element) { return element }
      }
      return nil
    }

    public func forEach(_ body: (Base.Element) throws -> Void) throws {
      try base.forEach { if try isIncluded($0) { try body($0) } }
    }
  }

  /// A cursor of pairs of an offset and an element.
  public final class EnumeratedCursor<Base: Cursor>: Cursor {
    private let base: Base
    private var index = 0

    init(_ base: Base) {
      self.base = base
    }

    public func next() throws -> (Int, Base.Element)? {
      guard let element = try base.next() else { return nil }
      defer { index += 1 }
      return (index, element)
    }

    public func forEach(_ body: ((Int, Base.Element)) throws -> Void) throws {
      try base.forEach { element in
        defer { index += 1 }
        try body((index, element))
      }
    }
  }

  /// A cursor of the first elements of a base cursor.
  public final class PrefixCursor<Base: Cursor>: Cursor {
    private let base: Base
    private var remaining: Int

    init(_ base: Base, _ maxLength: Int) {
      precondition(maxLength >= 0, "Can't take a prefix of negative length from a cursor")
      self.base = base
      remaining = maxLength
    }

    public func next() throws -> Base.Element? {
      guard remaining > 0 else { return nil }
      remaining -= 1
      return try base.next()
    }

    public func forEach(_ body: (Base.Element) throws -> Void) throws {
      while let element = try next() { try body(element) }
    }
  }

  /// A cursor of the first elements that satisfy a predicate.
  public final class PrefixWhileCursor<Base: Cursor>: Cursor {
    private let base: Base
    private let predicate: (Base.Element) throws -> Bool
    private var finished = false

    init(_ base: Base, _ predicate: @escaping (Base.Element) throws -> Bool) {
      self.base = base
      self.predicate = predicate
    }

    public func next() throws -> Base.Element? {
      guard !finished else { return nil }
      guard let element = try base.next(), try predicate(element) else {
        finished = true
        return nil
      }
      return element
    }

    public func forEach(_ body: (Base.Element) throws -> Void) throws {
      while let element = try next() { try body(element) }
    }
  }

  /// A cursor that skips the first elements of a base cursor.
  public final class DropFirstCursor<Base: Cursor>: Cursor {
    private let base: Base
    private let limit: Int
    private var dropped = false

    init(_ base: Base, _ limit: Int) {
      precondition(limit >= 0, "Can't drop a negative number of elements from a cursor")
      self.base = base
      self.limit = limit
    }

    public func next() throws -> Base.Element? {
      if !dropped {
        dropped = true
        for _ in 0..<limit {
          if try base.next() == nil { return nil }
        }
      }
      return try base.next()
    }

    public func forEach(_ body: (Base.Element) throws -> Void) throws {
      while let element = try next() { try body(element) }
    }
  }

  /// A cursor that skips the first elements that satisfy a predicate.
  public final class DropWhileCursor<Base: Cursor>: Cursor {
    private let base: Base
    private let predicate: (Base.Element) throws -> Bool
    private var dropping = true

    init(_ base: Base, _ predicate: @escaping (Base.Element) throws -> Bool) {
      self.base = base
      self.predicate = predicate
    }

    public func next() throws -> Base.Element? {
      while let element = try base.next() {
        if dropping {
          dropping = try predicate(element)
          if dropping { continue }
        }
        return element
      }
      return nil
    }

    public func forEach(_ body: (Base.Element) throws -> Void) throws {
      while let element = try next() { try body(element) }
    }
  }

  /// A cursor of the elements of the cursors of a base cursor.
  public final class FlattenCursor<Base: Cursor>: Cursor where Base.Element: Cursor {
    private let base: Base
    private var inner: Base.Element?

    init(_ base: Base) {
      self.base = base
    }

    public func next() throws -> Base.Element.Element? {
      while true {
        if let element = try inner?.next() { return element }
        guard let next = try base.next() else { return nil }
        inner = next
      }
    }

    public func forEach(_ body: (Base.Element.Element) throws -> Void) throws {
      while let element = try next() { try body(element) }
    }
  }

  extension Cursor {
    /// Testing emptiness consumes the first element, if present.
    public var isEmpty: Bool {
      get throws {
        try next() == nil
      }
    }

    public func map<T>(_ transform: @escaping (Element) throws -> T) -> MapCursor<Self, T> {
      MapCursor(self, transform)
    }

    public func filter(_ isIncluded: @escaping (Element) throws -> Bool) -> FilterCursor<Self> {
      FilterCursor(self, isIncluded)
    }

    public func compactMap<ElementOfResult>(
      _ transform: @escaping (Element) throws -> ElementOfResult?
    ) -> MapCursor<FilterCursor<MapCursor<Self, ElementOfResult?>>, ElementOfResult> {
      map(transform).filter { $0 != nil }.map { $0! }
    }

    public func forEach(_ body: (Element) throws -> Void) throws {
      while let value = try next() {
        try body(value)
      }
    }

    public func reduce<T>(_ initial: T, _ nextPartialResult: (T, Element) throws -> T) throws -> T {
      var result = initial
      try forEach { result = try nextPartialResult(result, $0) }
      return result
    }

    public func first(where predicate: (Element) throws -> Bool) throws -> Element? {
      while let value = try next() {
        if try predicate(value) {
          return value
        }
      }
      return nil
    }

    public func contains(where predicate: (Element) throws -> Bool) throws -> Bool {
      try first(where: predicate) != nil
    }

    public func enumerated() -> EnumeratedCursor<Self> {
      EnumeratedCursor(self)
    }

    public func prefix(_ maxLength: Int) -> PrefixCursor<Self> {
      PrefixCursor(self, maxLength)
    }

    public func prefix(while predicate: @escaping (Element) throws -> Bool) -> PrefixWhileCursor<
      Self
    > {
      PrefixWhileCursor(self, predicate)
    }

    public func dropFirst(_ n: Int) -> DropFirstCursor<Self> {
      DropFirstCursor(self, n)
    }

    public func dropFirst() -> DropFirstCursor<Self> {
      dropFirst(1)
    }

    public func drop(while predicate: @escaping (Element) throws -> Bool) -> DropWhileCursor<Self> {
      DropWhileCursor(self, predicate)
    }

    public func flatMap<SegmentOfResult: Cursor>(
      _ transform: @escaping (Element) throws -> SegmentOfResult
    ) -> FlattenCursor<MapCursor<Self, SegmentOfResult>> {
      FlattenCursor(map(transform))
    }

    public func flatMap<SegmentOfResult: Sequence>(
      _ transform: @escaping (Element) throws -> SegmentOfResult
    ) -> FlattenCursor<MapCursor<Self, AnyCursor<SegmentOfResult.Element>>> {
      FlattenCursor(map { try AnyCursor(transform($0)) })
    }

    public func reduce<T>(into initialResult: T, _ update: (inout T, Element) throws -> Void)
      throws -> T
    {
      var result = initialResult
      try forEach { try update(&result, $0) }
      return result
    }

    public func max(by less: (Element, Element) throws -> Bool) throws -> Element? {
      guard var result = try next() else {
        return nil
      }
      while let value = try next() {
        if try less(result, value) {
          result = value
        }
      }
      return result
    }

    public func min(by less: (Element, Element) throws -> Bool) throws -> Element? {
      try max { try less($1, $0) }
    }

    public func dropLast(_ count: Int = 1) throws -> [Element] {
      precondition(count >= 0)
      guard count > 0 else {
        return try Array(self)
      }
      var tail: [Element] = []
      var result: [Element] = []
      var index = 0
      while let value = try next() {
        if tail.count < count {
          tail.append(value)
        } else {
          result.append(tail[index])
          tail[index] = value
          index = (index + 1) % count
        }
      }
      return result
    }

    public func suffix(_ maxLength: Int) throws -> [Element] {
      precondition(maxLength >= 0)
      guard maxLength > 0 else {
        return []
      }
      var result: [Element] = []
      var index = 0
      while let value = try next() {
        if result.count < maxLength {
          result.append(value)
        } else {
          result[index] = value
          index = (index + 1) % maxLength
        }
      }
      return Array(result[index...] + result[..<index])
    }
  }

  extension Cursor where Element: Equatable {
    public func contains(_ value: Element) throws -> Bool {
      try contains { $0 == value }
    }
  }

  extension Cursor where Element: Comparable {
    public func min() throws -> Element? {
      try min(by: <)
    }

    public func max() throws -> Element? {
      try max(by: <)
    }
  }

  extension Cursor where Element: Cursor {
    public func joined() -> FlattenCursor<Self> {
      FlattenCursor(self)
    }
  }

  extension Cursor where Element: Sequence {
    public func joined() -> FlattenCursor<MapCursor<Self, AnyCursor<Element.Element>>> {
      FlattenCursor(map { AnyCursor($0) })
    }
  }

  extension Cursor where Element: StringProtocol {
    public func joined(separator: String = "") throws -> String {
      var result = ""
      var isFirst = true
      try forEach { value in
        if !isFirst {
          result += separator
        }
        result += value
        isFirst = false
      }
      return result
    }
  }

  extension Sequence {
    public func flatMap<SegmentOfResult: Cursor>(
      _ transform: @escaping (Element) throws -> SegmentOfResult
    ) -> FlattenCursor<MapCursor<AnyCursor<Element>, SegmentOfResult>> {
      FlattenCursor(AnyCursor(self).map(transform))
    }
  }

  extension RangeReplaceableCollection {
    public init(_ cursor: some Cursor<Element>) throws {
      self.init()
      try append(contentsOf: cursor)
    }

    public init(_ cursor: some Cursor<Element>, minimumCapacity: Int) throws {
      self.init()
      reserveCapacity(minimumCapacity)
      try append(contentsOf: cursor)
    }

    public mutating func append<C: Cursor>(contentsOf cursor: C) throws where C.Element == Element {
      try cursor.forEach { append($0) }
    }
  }

  extension Set {
    public init(_ cursor: some Cursor<Element>) throws {
      self.init()
      try formUnion(cursor)
    }

    public init(_ cursor: some Cursor<Element>, minimumCapacity: Int) throws {
      self.init(minimumCapacity: minimumCapacity)
      try formUnion(cursor)
    }

    public mutating func formUnion<C: Cursor>(_ cursor: C) throws where C.Element == Element {
      try cursor.forEach { _ = insert($0) }
    }

    public func union<C: Cursor>(_ cursor: C) throws -> Self where C.Element == Element {
      var result = self
      try result.formUnion(cursor)
      return result
    }

    public func intersection<C: Cursor>(_ cursor: C) throws -> Self where C.Element == Element {
      intersection(try Set(cursor))
    }

    public mutating func formIntersection<C: Cursor>(_ cursor: C) throws
    where C.Element == Element {
      self = try intersection(cursor)
    }
  }

  extension Dictionary {
    public init<C: Cursor>(grouping cursor: C, by keyForValue: (C.Element) throws -> Key) throws
    where Value == [C.Element] {
      try self.init(minimumCapacity: 0, grouping: cursor, by: keyForValue)
    }

    public init<C: Cursor>(
      minimumCapacity: Int,
      grouping cursor: C,
      by keyForValue: (C.Element) throws -> Key
    ) throws where Value == [C.Element] {
      self.init(minimumCapacity: minimumCapacity)
      try cursor.forEach { value in self[try keyForValue(value), default: []].append(value) }
    }

    public init(uniqueKeysWithValues keysAndValues: some Cursor<(Key, Value)>) throws {
      try self.init(minimumCapacity: 0, uniqueKeysWithValues: keysAndValues)
    }

    public init(minimumCapacity: Int, uniqueKeysWithValues keysAndValues: some Cursor<(Key, Value)>)
      throws
    {
      self.init(minimumCapacity: minimumCapacity)
      try keysAndValues.forEach { key, value in
        precondition(updateValue(value, forKey: key) == nil, "Duplicate key: \(key)")
      }
    }
  }
#endif
