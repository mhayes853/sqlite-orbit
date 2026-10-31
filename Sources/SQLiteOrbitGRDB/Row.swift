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
    // Whether the row was fetched from the database, rather than built from values.
    var storedIsFetched = false
    var isFetched: Bool { base?.isFetched ?? storedIsFetched }
    private let base: Row?
    private let adapter: (any _LayoutedRowAdapter)?
    private let mapping: _LayoutedColumnMapping?

    /// The rows prefetched with `including(all:)`, by association key.
    public internal(set) var prefetchedRows = PrefetchedRowsView()

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

    public subscript(_ column: some ColumnExpression) -> (any DatabaseValueConvertible)? {
      self[column.name]
    }

    /// Decodes the value of a column.
    public func decode<T: DatabaseValueConvertible>(
      _ type: T.Type = T.self,
      forColumn column: some ColumnExpression
    ) throws -> T {
      try decode(type, forColumn: column.name)
    }

    /// Calls `body` with the data of a column, or nil for NULL. Text is accessed as UTF-8 data.
    public func withUnsafeData<T>(atIndex index: Int, _ body: (Data?) throws -> T) throws -> T {
      let value = column(at: index).1
      switch value.storage {
      case .null: return try body(nil)
      case .blob(let data): return try body(data)
      case .string(let string): return try body(Data(string.utf8))
      default:
        throw RowDecodingError(column: column(at: index).0, databaseValue: value, type: Data.self)
      }
    }

    /// Calls `body` with the data of a column, or nil for a missing column or NULL.
    public func withUnsafeData<T>(named name: String, _ body: (Data?) throws -> T) throws -> T {
      guard let index = index(ofColumn: name) else { return try body(nil) }
      return try withUnsafeData(atIndex: index, body)
    }

    /// Calls `body` with the data of a column, or nil for a missing column or NULL.
    public func withUnsafeData<T>(
      at column: some ColumnExpression,
      _ body: (Data?) throws -> T
    ) throws -> T {
      try withUnsafeData(named: column.name, body)
    }

    /// Returns the data of a column, or nil for NULL.
    public func dataNoCopy(atIndex index: Int) -> Data? {
      self[index] as Data?
    }

    /// Returns the data of a column, or nil for a missing column or NULL.
    public func dataNoCopy(named name: String) -> Data? {
      self[name] as Data?
    }

    /// Returns the data of a column, or nil for a missing column or NULL.
    public func dataNoCopy(_ column: some ColumnExpression) -> Data? {
      self[column.name] as Data?
    }

    public var description: String {
      "[" + columns.map { $0.0 + ":" + $0.1.description }.joined(separator: " ") + "]"
    }

    public var debugDescription: String {
      debugDescription(level: 0)
    }

    private func debugDescription(level: Int) -> String {
      if level == 0 && self == unadapted && prefetchedRows.isEmpty {
        return description
      }
      let prefix = String(repeating: "  ", count: level + 1)
      var result: String
      if level == 0 {
        result = "▿ " + description
        let unadapted = self.unadapted
        if self != unadapted {
          result += "\n" + prefix + "unadapted: " + unadapted.description
        }
      } else {
        result = description
      }
      for (name, scoped) in scopes.sorted(by: { $0.name < $1.name }) {
        result += "\n" + prefix + "- " + name + ": " + scoped.debugDescription(level: level + 1)
      }
      for key in prefetchedRows.keys.sorted() {
        guard let rows = prefetchedRows[key] else { continue }
        let count = rows.count == 1 ? "1 row" : rows.count == 0 ? "0 row" : "\(rows.count) rows"
        result += "\n" + prefix + "+ " + key + ": " + count
      }
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
        let row = Row(base: base.copy(), adapter: adapter)
        row.prefetchedRows = prefetchedRows
        return row
      }
      let row = Row(storedColumns)
      row.storedIsFetched = storedIsFetched
      row.prefetchedRows = prefetchedRows
      return row
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
        && lhs.prefetchedRows == rhs.prefetchedRows
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
      ScopesView(
        base: base ?? self,
        adapters: adapter?._scopes ?? [:],
        prefetchedRows: prefetchedRows
      )
    }

    /// Recursive scope lookup, visiting all children before their descendants.
    public var scopesTree: ScopesTreeView {
      ScopesTreeView(scopes: scopes)
    }

    /// The same column projection without named scopes.
    public var unscoped: Row {
      guard let base, let adapter else {
        if prefetchedRows.isEmpty { return self }
        let row = Row(storedColumns)
        row.storedIsFetched = storedIsFetched
        return row
      }
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
      private let prefetchedRows: PrefetchedRowsView

      fileprivate init(
        base: Row,
        adapters: [String: any _LayoutedRowAdapter],
        prefetchedRows: PrefetchedRowsView
      ) {
        self.base = base
        self.adapters = adapters
        self.prefetchedRows = prefetchedRows
      }

      // A scoped row gives access to the rows prefetched for its own associations.
      private func scopedRow(_ name: String, _ adapter: any _LayoutedRowAdapter) -> Row {
        let row = Row(base: base, adapter: adapter)
        if let prefetch = prefetchedRows.prefetches.first(where: { $0.key == name })?.prefetch {
          row.prefetchedRows = PrefetchedRowsView(prefetches: prefetch.prefetches)
        }
        return row
      }

      public var names: Dictionary<String, any _LayoutedRowAdapter>.Keys { adapters.keys }
      public var startIndex: Index { adapters.startIndex }
      public var endIndex: Index { adapters.endIndex }

      public func index(after index: Index) -> Index {
        adapters.index(after: index)
      }

      public subscript(position: Index) -> (name: String, row: Row) {
        let (name, adapter) = adapters[position]
        return (name, scopedRow(name, adapter))
      }

      public subscript(_ name: String) -> Row? {
        adapters[name].map { scopedRow(name, $0) }
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

  extension Row {
    /// A view on the rows prefetched with `including(all:)`.
    public struct PrefetchedRowsView: Equatable, @unchecked Sendable {
      struct Prefetch: Equatable {
        /// Nil for intermediate (through) associations.
        var rows: [Row]?
        var prefetches: [(key: String, prefetch: Prefetch)]

        static func == (lhs: Prefetch, rhs: Prefetch) -> Bool {
          lhs.rows == rhs.rows && lhs.prefetches.elementsEqual(rhs.prefetches) { $0 == $1 }
        }
      }

      var prefetches: [(key: String, prefetch: Prefetch)] = []

      init() {}

      init(prefetches: [(key: String, prefetch: Prefetch)]) {
        self.prefetches = prefetches
      }

      public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.prefetches.elementsEqual(rhs.prefetches) { $0 == $1 }
      }

      public var isEmpty: Bool { prefetches.isEmpty }

      /// The keys of all prefetched rows, including nested associations.
      public var keys: Set<String> {
        var result: Set<String> = []
        var pending = prefetches
        var index = 0
        while index < pending.count {
          let (key, prefetch) = pending[index]
          if prefetch.rows != nil { result.insert(key) }
          pending += prefetch.prefetches
          index += 1
        }
        return result
      }

      /// The prefetched rows for a key, searched breadth-first.
      public subscript(_ key: String) -> [Row]? {
        var pending = prefetches
        var index = 0
        while index < pending.count {
          let (prefetchKey, prefetch) = pending[index]
          if prefetchKey == key, let rows = prefetch.rows { return rows }
          pending += prefetch.prefetches
          index += 1
        }
        return nil
      }

      mutating func setRows(_ rows: [Row], forKeyPath keyPath: [String]) {
        Self.setRows(rows, forKeyPath: keyPath[...], in: &prefetches)
      }

      private static func setRows(
        _ rows: [Row],
        forKeyPath keyPath: ArraySlice<String>,
        in prefetches: inout [(key: String, prefetch: Prefetch)]
      ) {
        guard let key = keyPath.first else { return }
        let index =
          prefetches.firstIndex { $0.key == key }
          ?? {
            prefetches.append((key, Prefetch(rows: nil, prefetches: [])))
            return prefetches.count - 1
          }()
        if keyPath.count == 1 {
          prefetches[index].prefetch.rows = rows
        } else {
          setRows(rows, forKeyPath: keyPath.dropFirst(), in: &prefetches[index].prefetch.prefetches)
        }
      }
    }

    private func prefetchedRowsForKey(_ key: String) throws -> [Row] {
      guard let rows = prefetchedRows[key] else {
        let keys = prefetchedRows.keys
        var message = "key for prefetched rows not found: \(String(reflecting: key))"
        if !keys.isEmpty { message += " - available keys: \(keys.sorted())" }
        throw DatabaseError(resultCode: .SQLITE_ERROR, message: message)
      }
      return rows
    }

    /// Decodes the records prefetched for an association key.
    public func decode<Records: RangeReplaceableCollection>(
      _ type: Records.Type = Records.self,
      forKey key: String
    ) throws -> Records where Records.Element: FetchableRecord {
      var records = Records()
      for row in try prefetchedRowsForKey(key) {
        records.append(try Records.Element(row: row))
      }
      return records
    }

    /// Decodes the set of records prefetched for an association key.
    public func decode<Record: FetchableRecord & Hashable>(
      _ type: Set<Record>.Type = Set<Record>.self,
      forKey key: String
    ) throws -> Set<Record> {
      try Set(prefetchedRowsForKey(key).map { try Record(row: $0) })
    }

    public subscript<Records: RangeReplaceableCollection>(_ key: String) -> Records
    where Records.Element: FetchableRecord {
      try! decode(Records.self, forKey: key)
    }

    public subscript<Record: FetchableRecord & Hashable>(_ key: String) -> Set<Record> {
      try! decode(Set<Record>.self, forKey: key)
    }
  }

  extension DatabaseValueConvertible {
    public static func fetchCursor(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> AnyCursor<Self> {
      AnyCursor(
        try Row.fetchCursor(db, sql: sql, arguments: arguments, adapter: adapter)
          .map { try $0.decode(Self.self, at: 0) }
      )
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
      AnyCursor(
        try Row.fetchCursor(statement, arguments: arguments, adapter: adapter)
          .map { try $0.decode(Self.self, at: 0) }
      )
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
      let (sql, arguments) = try literal.build(db)
      return try fetchAll(db, sql: sql, arguments: arguments)
    }

    public static func fetchOne(_ db: Database, _ literal: SQL) throws -> Self? {
      let (sql, arguments) = try literal.build(db)
      return try fetchOne(db, sql: sql, arguments: arguments)
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
