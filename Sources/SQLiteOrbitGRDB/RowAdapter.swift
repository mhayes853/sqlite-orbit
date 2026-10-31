#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// Resolves a row projection and its named scopes against a result's columns.
  public protocol RowAdapter: Sendable {
    func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter
  }

  /// Column metadata used by custom row adapters. Underscored names match GRDB's public contract.
  public protocol _RowLayout {
    /// Pairs of base column indexes and exposed names, in result order.
    var _layoutColumns: [(Int, String)] { get }
    func _layoutIndex(ofColumn name: String) -> Int?
  }

  /// A resolved column mapping and recursively resolved named scopes.
  public protocol _LayoutedRowAdapter {
    var _mapping: _LayoutedColumnMapping { get }
    var _scopes: [String: any _LayoutedRowAdapter] { get }
  }

  /// A resolved mapping. Custom adapters can obtain one by resolving a built-in adapter.
  public struct _LayoutedColumnMapping: _LayoutedRowAdapter, _RowLayout {
    public let _layoutColumns: [(Int, String)]
    private let indexes: [String: Int]

    init(layoutColumns: some Collection<(Int, String)>) {
      _layoutColumns = Array(layoutColumns)
      indexes = Dictionary(
        layoutColumns.enumerated().map { ($0.element.1.lowercased(), $0.offset) },
        uniquingKeysWith: { first, _ in first }
      )
    }

    public var _mapping: Self { self }
    public var _scopes: [String: any _LayoutedRowAdapter] { [:] }

    public func _layoutIndex(ofColumn name: String) -> Int? {
      indexes[name.lowercased()]
    }
  }

  extension Statement: _RowLayout {
    public var _layoutColumns: [(Int, String)] { Array(columnNames.enumerated()) }

    public func _layoutIndex(ofColumn name: String) -> Int? {
      columnNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
  }

  /// Hides all columns in the adapted row.
  public struct EmptyRowAdapter: RowAdapter {
    public init() {}

    public func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
      _LayoutedColumnMapping(layoutColumns: [])
    }
  }

  /// Selects and renames columns, preserving their source order.
  public struct ColumnMapping: RowAdapter {
    private let mapping: [String: String]

    /// Maps destination column names to source column names.
    public init(_ mapping: [String: String]) {
      self.mapping = mapping
    }

    public func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
      let columns = layout._layoutColumns
      let mapped = try mapping.map { destination, source -> (Int, String) in
        guard let index = layout._layoutIndex(ofColumn: source) else {
          throw DatabaseError(
            resultCode: .SQLITE_MISUSE,
            message: "Mapping references missing column \(source). Valid column names are: "
              + columns.map(\.1).joined(separator: ", ") + "."
          )
        }
        return (columns[index].0, destination)
      }
      return _LayoutedColumnMapping(layoutColumns: mapped.sorted { $0.0 < $1.0 })
    }
  }

  /// Renames every column without changing its position or value.
  public struct RenameColumnAdapter: RowAdapter {
    private let transform: @Sendable (String) -> String

    public init(_ transform: @escaping @Sendable (String) -> String) {
      self.transform = transform
    }

    public func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
      _LayoutedColumnMapping(layoutColumns: layout._layoutColumns.map { ($0.0, transform($0.1)) })
    }
  }

  /// Exposes a range of columns. The range must fit the result's column layout.
  public struct RangeRowAdapter: RowAdapter {
    private let range: Range<Int>

    public init(_ range: Range<Int>) {
      precondition(range.lowerBound >= 0, "Negative column index is out of range")
      self.range = range
    }

    public init(_ range: ClosedRange<Int>) {
      self.init(range.lowerBound..<(range.upperBound + 1))
    }

    public func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
      _LayoutedColumnMapping(layoutColumns: layout._layoutColumns[range])
    }
  }

  /// Hides columns before the specified index, which must fit the result's column layout.
  public struct SuffixRowAdapter: RowAdapter {
    private let index: Int

    public init(fromIndex index: Int) {
      precondition(index >= 0, "Negative column index is out of range")
      self.index = index
    }

    public func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
      _LayoutedColumnMapping(layoutColumns: layout._layoutColumns.suffix(from: index))
    }
  }

  /// Splits columns into fixed-size chunks, followed by an adapter for all remaining columns.
  public func splittingRowAdapters(columnCounts: [Int]) -> [any RowAdapter] {
    var start = 0
    var adapters: [any RowAdapter] = []
    for count in columnCounts {
      adapters.append(RangeRowAdapter(start..<(start + count)))
      start += count
    }
    adapters.append(SuffixRowAdapter(fromIndex: start))
    return adapters
  }

  /// Adds named row views. Scopes resolve against the input layout, independently of the base view.
  public struct ScopeAdapter: RowAdapter {
    private let base: any RowAdapter
    private let scopes: [String: any RowAdapter]

    public init(_ scopes: [String: any RowAdapter]) {
      self.init(base: SuffixRowAdapter(fromIndex: 0), scopes: scopes)
    }

    public init(base: some RowAdapter, scopes: [String: any RowAdapter]) {
      self.base = base
      self.scopes = scopes
    }

    public func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
      let resolved = try base._layoutedAdapter(from: layout)
      var scopes = resolved._scopes
      for (name, adapter) in self.scopes {
        scopes[name] = try adapter._layoutedAdapter(from: layout)
      }
      return LayoutedScopeAdapter(_mapping: resolved._mapping, _scopes: scopes)
    }
  }

  extension RowAdapter {
    /// Adds scopes, replacing any existing scopes with the same names.
    public func addingScopes(_ scopes: [String: any RowAdapter]) -> any RowAdapter {
      scopes.isEmpty ? self : ScopeAdapter(base: self, scopes: scopes)
    }
  }

  private struct LayoutedScopeAdapter: _LayoutedRowAdapter {
    let _mapping: _LayoutedColumnMapping
    let _scopes: [String: any _LayoutedRowAdapter]
  }

  struct ChainedAdapter: RowAdapter {
    let first: any RowAdapter
    let second: any RowAdapter

    func _layoutedAdapter(from layout: some _RowLayout) throws -> any _LayoutedRowAdapter {
      try second._layoutedAdapter(from: first._layoutedAdapter(from: layout)._mapping)
    }
  }
#endif
