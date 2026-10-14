#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public struct RowDecodingError: Error, CustomStringConvertible {
    public let column: String
    public let databaseValue: DatabaseValue
    public let type: Any.Type

    public var description: String {
      "could not decode \(type) from \(databaseValue) at column \(column)"
    }
  }

  /// Owned values. Rows returned by fetchAll/fetchOne are independent of their connection; a cursor
  /// reuses its row until the caller makes a copy, following GRDB's cursor contract.
  public final class Row: @unchecked Sendable, Hashable, RandomAccessCollection,
    ExpressibleByDictionaryLiteral
  {
    var columns: [(String, DatabaseValue)]

    public init() {
      columns = []
    }

    init(_ columns: [(String, DatabaseValue)]) {
      self.columns = columns
    }

    public convenience init(_ dictionary: [String: (any DatabaseValueConvertible)?]) {
      self.init(dictionary.map { ($0.key, $0.value?.databaseValue ?? .null) })
    }

    public convenience init(
      dictionaryLiteral elements: (String, (any DatabaseValueConvertible)?)...
    ) {
      self.init(elements.map { ($0.0, $0.1?.databaseValue ?? .null) })
    }

    public struct Index: Comparable, Strideable, Sendable {
      fileprivate let offset: Int

      public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.offset < rhs.offset
      }

      public func distance(to other: Self) -> Int {
        other.offset - offset
      }

      public func advanced(by n: Int) -> Self {
        Self(offset: offset + n)
      }
    }

    public var startIndex: Index {
      Index(offset: 0)
    }

    public var endIndex: Index {
      Index(offset: columns.count)
    }

    public func index(after i: Index) -> Index {
      i.advanced(by: 1)
    }

    public func index(before i: Index) -> Index {
      i.advanced(by: -1)
    }

    public subscript(position: Index) -> (String, DatabaseValue) {
      columns[position.offset]
    }

    public subscript(_ index: Int) -> (any DatabaseValueConvertible)? {
      columns[index].1.rawValue
    }

    public subscript(_ column: String) -> (any DatabaseValueConvertible)? {
      index(ofColumn: column).flatMap { columns[$0].1.rawValue }
    }

    public subscript<T: DatabaseValueConvertible>(_ index: Int) -> T {
      do {
        return try decode(T.self, at: index)
      } catch {
        preconditionFailure(String(describing: error))
      }
    }

    public subscript<T: DatabaseValueConvertible>(_ column: String) -> T {
      do {
        return try decode(T.self, forColumn: column)
      } catch {
        preconditionFailure(String(describing: error))
      }
    }

    public subscript<T: DatabaseValueConvertible>(_ column: some ColumnExpression) -> T {
      self[column.name]
    }

    public var columnNames: [String] {
      columns.map(\.0)
    }

    public var databaseValues: [DatabaseValue] {
      columns.map(\.1)
    }

    public func hasColumn(_ column: String) -> Bool {
      index(ofColumn: column) != nil
    }

    public func index(ofColumn column: String) -> Int? {
      columns.firstIndex { $0.0.caseInsensitiveCompare(column) == .orderedSame }
    }

    public func copy() -> Row {
      Row(columns)
    }

    public func decode<T: DatabaseValueConvertible>(_ type: T.Type = T.self, at index: Int) throws
      -> T
    {
      guard columns.indices.contains(index) else {
        throw RowDecodingError(column: String(index), databaseValue: .null, type: type)
      }
      guard let value = T.fromDatabaseValue(columns[index].1) else {
        throw RowDecodingError(
          column: columns[index].0,
          databaseValue: columns[index].1,
          type: type
        )
      }
      return value
    }

    public func decode<T: DatabaseValueConvertible>(
      _ type: T.Type = T.self,
      forColumn column: String
    )
      throws -> T
    {
      guard let index = index(ofColumn: column) else {
        if let optional = T.self as? any OptionalDatabaseColumn.Type {
          return optional.nilValue as! T
        }
        throw RowDecodingError(column: column, databaseValue: .null, type: type)
      }
      return try decode(type, at: index)
    }

    public func decode<T: DatabaseValueConvertible>(_ type: T.Type = T.self, atIndex index: Int)
      throws -> T
    {
      try decode(type, at: index)
    }

    public static func == (lhs: Row, rhs: Row) -> Bool {
      lhs.columnNames == rhs.columnNames && lhs.databaseValues == rhs.databaseValues
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(columnNames)
      hasher.combine(databaseValues)
    }
  }

  public protocol Cursor: AnyObject {
    associatedtype Element

    func next() throws -> Element?
  }

  public final class AnyCursor<Element>: Cursor {
    private let advance: () throws -> Element?

    public init<C: Cursor>(_ cursor: C) where C.Element == Element {
      advance = cursor.next
    }

    init(_ advance: @escaping () throws -> Element?) {
      self.advance = advance
    }

    public func next() throws -> Element? {
      try advance()
    }
  }

  extension Cursor {
    public func map<T>(_ transform: @escaping (Element) throws -> T) -> AnyCursor<T> {
      AnyCursor { try self.next().map(transform) }
    }

    public func filter(_ predicate: @escaping (Element) throws -> Bool) -> AnyCursor<Element> {
      AnyCursor {
        while let value = try self.next() {
          if try predicate(value) {
            return value
          }
        }
        return nil
      }
    }

    public func compactMap<T>(_ transform: @escaping (Element) throws -> T?) -> AnyCursor<T> {
      AnyCursor {
        while let value = try self.next() {
          if let result = try transform(value) {
            return result
          }
        }
        return nil
      }
    }

    public func forEach(_ body: (Element) throws -> Void) throws {
      while let value = try next() {
        try body(value)
      }
    }

    public func reduce<T>(_ initial: T, _ nextPartialResult: (T, Element) throws -> T) throws -> T {
      var result = initial
      while let value = try next() {
        result = try nextPartialResult(result, value)
      }
      return result
    }
  }

  extension Array {
    public init<C: Cursor>(_ cursor: C) throws where C.Element == Element {
      self.init()
      while let value = try cursor.next() {
        append(value)
      }
    }
  }

  extension DatabaseValueConvertible {
    public static func fetchCursor(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> AnyCursor<Self> {
      try Row.fetchCursor(db, sql: sql, arguments: arguments)
        .map { try $0.decode(Self.self, at: 0) }
    }

    public static func fetchAll(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> [Self] {
      try Array(fetchCursor(db, sql: sql, arguments: arguments))
    }

    public static func fetchOne(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> Self? {
      guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else {
        return nil
      }
      if let value = Self.fromDatabaseValue(row.databaseValues[0]) {
        return value
      }
      if row.databaseValues[0].isNull {
        return nil
      }
      return try row.decode(Self.self, at: 0)
    }

    public static func fetchCursor(_ statement: Statement, arguments: StatementArguments? = nil)
      throws -> AnyCursor<Self>
    {
      try Row.fetchCursor(statement, arguments: arguments).map { try $0.decode(Self.self, at: 0) }
    }

    public static func fetchAll(_ statement: Statement, arguments: StatementArguments? = nil) throws
      -> [Self]
    {
      try Array(fetchCursor(statement, arguments: arguments))
    }

    public static func fetchOne(_ statement: Statement, arguments: StatementArguments? = nil) throws
      -> Self?
    {
      guard let row = try Row.fetchOne(statement, arguments: arguments) else {
        return nil
      }
      if let value = Self.fromDatabaseValue(row.databaseValues[0]) {
        return value
      }
      if row.databaseValues[0].isNull {
        return nil
      }
      return try row.decode(Self.self, at: 0)
    }

    public static func fetchAll(_ db: Database, _ literal: SQL) throws -> [Self] {
      try fetchAll(db, sql: literal.sql, arguments: literal.arguments)
    }

    public static func fetchOne(_ db: Database, _ literal: SQL) throws -> Self? {
      try fetchOne(db, sql: literal.sql, arguments: literal.arguments)
    }
  }

  extension DatabaseValue {
    fileprivate var rawValue: (any DatabaseValueConvertible)? {
      switch storage {
      case .null: nil
      case .int64(let n): n
      case .double(let d): d
      case .string(let s): s
      case .blob(let data): data
      }
    }
  }

  private protocol OptionalDatabaseColumn {
    static var nilValue: Any { get }
  }

  extension Optional: OptionalDatabaseColumn {
    static var nilValue: Any {
      Self.none as Any
    }
  }

#endif
