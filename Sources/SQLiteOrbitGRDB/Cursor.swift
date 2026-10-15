// swift-format-ignore-file: ReplaceForEachWithForLoop

// Cursor is not a Sequence; custom forEach implementations must remain in use.
#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  extension AnyCursor {
    public convenience init<S: Sequence>(_ sequence: S) where S.Element == Element {
      self.init(iterator: sequence.makeIterator())
    }

    public convenience init<I: IteratorProtocol>(iterator: I) where I.Element == Element {
      var iterator = iterator
      self.init { iterator.next() }
    }
  }

  extension Cursor {
    /// Testing emptiness consumes the first element, if present.
    public var isEmpty: Bool {
      get throws {
        try next() == nil
      }
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

    public func enumerated() -> AnyCursor<(Int, Element)> {
      var offset = 0
      return map { value in
        defer {
          offset += 1
        }
        return (offset, value)
      }
    }

    public func prefix(_ maxLength: Int) -> AnyCursor<Element> {
      precondition(maxLength >= 0)
      var remaining = maxLength
      return AnyCursor {
        guard remaining > 0 else {
          return nil
        }
        remaining -= 1
        return try self.next()
      }
    }

    public func prefix(while predicate: @escaping (Element) throws -> Bool) -> AnyCursor<Element> {
      var finished = false
      return AnyCursor {
        guard !finished else {
          return nil
        }
        guard let value = try self.next(), try predicate(value) else {
          finished = true
          return nil
        }
        return value
      }
    }

    public func dropFirst(_ count: Int = 1) -> AnyCursor<Element> {
      precondition(count >= 0)
      var remaining = count
      return AnyCursor {
        while remaining > 0 {
          guard try self.next() != nil else {
            return nil
          }
          remaining -= 1
        }
        return try self.next()
      }
    }

    public func drop(while predicate: @escaping (Element) throws -> Bool) -> AnyCursor<Element> {
      var dropping = true
      return AnyCursor {
        while let value = try self.next() {
          if dropping {
            dropping = try predicate(value)
          }
          if !dropping {
            return value
          }
        }
        return nil
      }
    }

    public func flatMap<C: Cursor>(_ transform: @escaping (Element) throws -> C)
      -> AnyCursor<C.Element>
    {
      var current: C?
      return AnyCursor {
        while true {
          if let value = try current?.next() { return value }
          guard let value = try self.next() else { return nil }
          current = try transform(value)
        }
      }
    }

    public func flatMap<S: Sequence>(_ transform: @escaping (Element) throws -> S)
      -> AnyCursor<S.Element>
    {
      flatMap { try AnyCursor(transform($0)) }
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
    public func joined() -> AnyCursor<Element.Element> {
      flatMap { $0 }
    }
  }

  extension Cursor where Element: Sequence {
    public func joined() -> AnyCursor<Element.Element> {
      flatMap { $0 }
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
    public func flatMap<C: Cursor>(_ transform: @escaping (Element) throws -> C)
      -> AnyCursor<C.Element>
    {
      AnyCursor(self).flatMap(transform)
    }
  }

  extension RangeReplaceableCollection {
    public init<C: Cursor>(_ cursor: C, minimumCapacity: Int = 0) throws
    where C.Element == Element {
      self.init()
      reserveCapacity(minimumCapacity)
      try append(contentsOf: cursor)
    }

    public mutating func append<C: Cursor>(contentsOf cursor: C) throws where C.Element == Element {
      try cursor.forEach { append($0) }
    }
  }

  extension Set {
    public init<C: Cursor>(_ cursor: C, minimumCapacity: Int = 0) throws
    where C.Element == Element {
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
    public init<C: Cursor>(
      minimumCapacity: Int = 0,
      grouping cursor: C,
      by key: (C.Element) throws -> Key
    ) throws where Value == [C.Element] {
      self.init(minimumCapacity: minimumCapacity)
      try cursor.forEach { value in self[try key(value), default: []].append(value) }
    }

    public init<C: Cursor>(minimumCapacity: Int = 0, uniqueKeysWithValues cursor: C) throws
    where C.Element == (Key, Value) {
      self.init(minimumCapacity: minimumCapacity)
      try cursor.forEach { key, value in
        precondition(updateValue(value, forKey: key) == nil, "Duplicate dictionary key")
      }
    }
  }
#endif
