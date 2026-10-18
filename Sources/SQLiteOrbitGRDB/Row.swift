// swift-format-ignore-file: ReplaceForEachWithForLoop

// Cursor is not a Sequence; custom forEach implementations must remain in use.
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
    CustomStringConvertible, CustomDebugStringConvertible,
    ExpressibleByDictionaryLiteral
  {
    private var storedColumns: [(String, DatabaseValue)] = []
    private let base: Row?
    private let adapter: (any _LayoutedRowAdapter)?
    private let mapping: _LayoutedColumnMapping?

    var columns: [(String, DatabaseValue)] {
      get {
        guard let base, let mapping else { return storedColumns }
        let columns = base.columns
        return mapping._layoutColumns.map { (index, name) in (name, columns[index].1) }
      }
      set {
        precondition(base == nil)
        storedColumns = newValue
      }
    }

    public convenience init() {
      self.init([])
    }

    init(_ columns: [(String, DatabaseValue)]) {
      storedColumns = columns
      base = nil
      adapter = nil
      mapping = nil
    }

    init(base: Row, adapter: some _LayoutedRowAdapter) {
      self.base = base
      self.adapter = adapter
      mapping = adapter._mapping
    }

    private var columnCount: Int {
      mapping?._layoutColumns.count ?? storedColumns.count
    }

    private func column(at index: Int) -> (String, DatabaseValue) {
      guard let base, let mapping else { return storedColumns[index] }
      let (source, name) = mapping._layoutColumns[index]
      return (name, base.column(at: source).1)
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
      Index(offset: columnCount)
    }

    public func index(after i: Index) -> Index {
      i.advanced(by: 1)
    }

    public func index(before i: Index) -> Index {
      i.advanced(by: -1)
    }

    public subscript(position: Index) -> (String, DatabaseValue) {
      column(at: position.offset)
    }

    public subscript(_ index: Int) -> (any DatabaseValueConvertible)? {
      column(at: index).1.rawValue
    }

    public subscript(_ column: String) -> (any DatabaseValueConvertible)? {
      index(ofColumn: column).flatMap { self.column(at: $0).1.rawValue }
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

    public var description: String {
      "[" + columns.map { $0.0 + ":" + $0.1.description }.joined(separator: " ") + "]"
    }

    public var debugDescription: String {
      guard self != unadapted else { return description }
      var result = "▿ " + description
      result += "\n  unadapted: " + unadapted.description
      func appendScopes(_ row: Row, prefix: String) {
        for (name, scoped) in row.scopes.sorted(by: { $0.name < $1.name }) {
          result += "\n" + prefix + "- " + name + ": " + scoped.description
          appendScopes(scoped, prefix: prefix + "  ")
        }
      }
      appendScopes(self, prefix: "  ")
      return result
    }

    public var containsNonNullValue: Bool {
      (0..<columnCount).contains { !column(at: $0).1.isNull }
        || scopes.contains { $0.row.containsNonNullValue }
    }

    public func hasNull(atIndex index: Int) -> Bool {
      column(at: index).1.isNull
    }

    public func coalesce<T: DatabaseValueConvertible>(_ columns: some Collection<String>) -> T? {
      for column in columns {
        if let value = self[column] as T? {
          return value
        }
      }
      return nil
    }

    public func coalesce<T: DatabaseValueConvertible>(
      _ columns: some Collection<any ColumnExpression>
    ) -> T? {
      coalesce(columns.map(\.name))
    }

    public var columnNames: [String] {
      mapping?._layoutColumns.map(\.1) ?? storedColumns.map(\.0)
    }

    public var databaseValues: [DatabaseValue] {
      (0..<columnCount).map { column(at: $0).1 }
    }

    public func hasColumn(_ column: String) -> Bool {
      index(ofColumn: column) != nil
    }

    public func index(ofColumn column: String) -> Int? {
      if let mapping { return mapping._layoutIndex(ofColumn: column) }
      return storedColumns.firstIndex { $0.0.caseInsensitiveCompare(column) == .orderedSame }
    }

    public func copy() -> Row {
      if let base, let adapter {
        return Row(base: base.copy(), adapter: adapter)
      }
      return Row(storedColumns)
    }

    public func decode<T: DatabaseValueConvertible>(_ type: T.Type = T.self, at index: Int) throws
      -> T
    {
      guard (0..<columnCount).contains(index) else {
        throw RowDecodingError(column: String(index), databaseValue: .null, type: type)
      }
      let (name, databaseValue) = column(at: index)
      guard let value = T.fromDatabaseValue(databaseValue) else {
        throw RowDecodingError(
          column: name,
          databaseValue: databaseValue,
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
      if lhs === rhs { return true }
      return lhs.columnNames == rhs.columnNames && lhs.databaseValues == rhs.databaseValues
        && Set(lhs.scopes.names) == Set(rhs.scopes.names)
        && lhs.scopes.allSatisfy { rhs.scopes[$0.name] == $0.row }
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(columnNames)
      hasher.combine(databaseValues)
      for name in scopes.names.sorted() {
        hasher.combine(name)
        hasher.combine(scopes[name])
      }
    }
  }

  extension Row {
    /// The direct, case-sensitive named scopes defined by this row's adapter.
    public var scopes: ScopesView {
      ScopesView(base: base ?? self, adapters: adapter?._scopes ?? [:])
    }

    /// Recursive scope lookup, visiting all children before their descendants.
    public var scopesTree: ScopesTreeView {
      ScopesTreeView(scopes: scopes)
    }

    /// The same column projection without named scopes.
    public var unscoped: Row {
      guard let base, let adapter else { return self }
      return Row(base: base, adapter: adapter._mapping)
    }

    /// The original row before any column projection, renaming, or scoping.
    public var unadapted: Row {
      base?.unadapted ?? self
    }

    /// Decodes a required scoped record, throwing for missing or entirely NULL scopes.
    public func decode<Record: FetchableRecord>(
      _ type: Record.Type = Record.self,
      forKey scope: String
    ) throws -> Record {
      guard let row = scopesTree[scope], row.containsNonNullValue else {
        throw RowDecodingError(column: scope, databaseValue: .null, type: type)
      }
      return try Record(row: row)
    }

    /// Decodes a scoped record, or returns nil for a missing or entirely NULL scope.
    public func decodeIfPresent<Record: FetchableRecord>(
      _ type: Record.Type = Record.self,
      forKey scope: String
    ) throws -> Record? {
      guard let row = scopesTree[scope], row.containsNonNullValue else { return nil }
      return try Record(row: row)
    }

    public subscript<Record: FetchableRecord>(_ scope: String) -> Record {
      try! decode(forKey: scope)
    }

    public subscript<Record: FetchableRecord>(_ scope: String) -> Record? {
      try! decodeIfPresent(forKey: scope)
    }

    public struct ScopesView: Collection {
      public typealias Index = Dictionary<String, any _LayoutedRowAdapter>.Index
      private let base: Row
      private let adapters: [String: any _LayoutedRowAdapter]

      fileprivate init(base: Row, adapters: [String: any _LayoutedRowAdapter]) {
        self.base = base
        self.adapters = adapters
      }

      public var names: Dictionary<String, any _LayoutedRowAdapter>.Keys { adapters.keys }
      public var startIndex: Index { adapters.startIndex }
      public var endIndex: Index { adapters.endIndex }

      public func index(after index: Index) -> Index {
        adapters.index(after: index)
      }

      public subscript(position: Index) -> (name: String, row: Row) {
        let (name, adapter) = adapters[position]
        return (name, Row(base: base, adapter: adapter))
      }

      public subscript(_ name: String) -> Row? {
        adapters[name].map { Row(base: base, adapter: $0) }
      }
    }

    public struct ScopesTreeView {
      fileprivate let scopes: ScopesView

      public var names: Set<String> {
        scopes.reduce(into: []) { result, scope in
          result.insert(scope.name)
          result.formUnion(scope.row.scopesTree.names)
        }
      }

      public subscript(_ name: String) -> Row? {
        var pending = Array(scopes)
        var index = 0
        while index < pending.count {
          let scope = pending[index]
          if scope.name == name { return scope.row }
          pending.append(contentsOf: scope.row.scopes)
          index += 1
        }
        return nil
      }
    }
  }

  public protocol Cursor: AnyObject {
    associatedtype Element

    func next() throws -> Element?

    func forEach(_ body: (Element) throws -> Void) throws
  }

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

  extension Cursor {
    public func map<T>(_ transform: @escaping (Element) throws -> T) -> AnyCursor<T> {
      AnyCursor(
        { try self.next().map(transform) },
        forEach: { body in
          try self.forEach { try body(transform($0)) }
        }
      )
    }

    public func filter(_ predicate: @escaping (Element) throws -> Bool) -> AnyCursor<Element> {
      AnyCursor(
        {
          while let value = try self.next() {
            if try predicate(value) {
              return value
            }
          }
          return nil
        },
        forEach: { body in
          try self.forEach {
            if try predicate($0) {
              try body($0)
            }
          }
        }
      )
    }

    public func compactMap<T>(_ transform: @escaping (Element) throws -> T?) -> AnyCursor<T> {
      AnyCursor(
        {
          while let value = try self.next() {
            if let result = try transform(value) {
              return result
            }
          }
          return nil
        },
        forEach: { body in
          try self.forEach {
            if let result = try transform($0) {
              try body(result)
            }
          }
        }
      )
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

  extension DatabaseValueConvertible {
    public static func fetchCursor(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> AnyCursor<Self> {
      try Row.fetchCursor(db, sql: sql, arguments: arguments, adapter: adapter)
        .map { try $0.decode(Self.self, at: 0) }
    }

    public static func fetchAll(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> [Self] {
      try Array(fetchCursor(db, sql: sql, arguments: arguments, adapter: adapter))
    }

    public static func fetchOne(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> Self? {
      guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments, adapter: adapter) else {
        return nil
      }
      guard let first = row.databaseValues.first else {
        return try row.decode(Self.self, at: 0)
      }
      if let value = Self.fromDatabaseValue(first) {
        return value
      }
      if first.isNull {
        return nil
      }
      return try row.decode(Self.self, at: 0)
    }

    public static func fetchCursor(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    )
      throws -> AnyCursor<Self>
    {
      try Row.fetchCursor(statement, arguments: arguments, adapter: adapter)
        .map { try $0.decode(Self.self, at: 0) }
    }

    public static func fetchAll(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> [Self]
    {
      try Array(fetchCursor(statement, arguments: arguments, adapter: adapter))
    }

    public static func fetchOne(
      _ statement: Statement,
      arguments: StatementArguments? = nil,
      adapter: (any RowAdapter)? = nil
    ) throws
      -> Self?
    {
      guard let row = try Row.fetchOne(statement, arguments: arguments, adapter: adapter) else {
        return nil
      }
      guard let first = row.databaseValues.first else {
        return try row.decode(Self.self, at: 0)
      }
      if let value = Self.fromDatabaseValue(first) {
        return value
      }
      if first.isNull {
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
