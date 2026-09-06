public import StructuredQueries

/// A set of columns in a database.
///
/// A region can cover no columns, every column in the database, every column in particular
/// tables, or particular columns in those tables. Regions are standalone values: constructing
/// one does not open or inspect a database.
///
/// ```swift
/// let titles = OrbitDatabaseRegion(column: "title", in: "reminders")
/// let reminders = OrbitDatabaseRegion(Reminder.self)
/// let observed = titles.union(Tag.databaseRegion)
/// ```
public struct OrbitDatabaseRegion: Hashable, Sendable {
  private struct TableIdentifier: Hashable, Sendable {
    let schema: String?
    let name: String

    init(schema: String?, name: String) {
      self.schema = schema?.asciiLowercased
      self.name = name.asciiLowercased
    }
  }

  private enum TableRegion: Hashable, Sendable {
    case allColumns
    case columns(Set<String>)

    func union(_ other: Self) -> Self {
      switch (self, other) {
      case (.allColumns, _), (_, .allColumns):
        return .allColumns
      case (.columns(let columns), .columns(let otherColumns)):
        return .columns(columns.union(otherColumns))
      }
    }

    func intersection(_ other: Self) -> Self? {
      switch (self, other) {
      case (.allColumns, let region), (let region, .allColumns):
        return region
      case (.columns(let columns), .columns(let otherColumns)):
        let intersection = columns.intersection(otherColumns)
        return intersection.isEmpty ? nil : .columns(intersection)
      }
    }

    func contains(_ other: Self) -> Bool {
      switch (self, other) {
      case (.allColumns, _):
        return true
      case (.columns, .allColumns):
        return false
      case (.columns(let columns), .columns(let otherColumns)):
        return columns.isSuperset(of: otherColumns)
      }
    }
  }

  // `nil` is the full database. An empty dictionary is the empty region.
  private let tableRegions: [TableIdentifier: TableRegion]?

  private init(tableRegions: [TableIdentifier: TableRegion]?) {
    self.tableRegions = tableRegions
  }

  /// The empty database region.
  public static let empty = Self()

  /// The region containing every column in the database.
  public static let fullDatabase = Self(tableRegions: nil)

  /// Creates the empty database region.
  public init() {
    self.init(tableRegions: [:])
  }

  /// Creates a region containing every column in a table.
  ///
  /// - Parameters:
  ///   - table: The table's name.
  ///   - schema: The table's schema, or `nil` for an unqualified table name.
  public init(table: String, schema: String? = nil) {
    self.init(
      tableRegions: [TableIdentifier(schema: schema, name: table): .allColumns]
    )
  }

  /// Creates a region containing one column in a table.
  ///
  /// - Parameters:
  ///   - column: The column's name.
  ///   - table: The table's name.
  ///   - schema: The table's schema, or `nil` for an unqualified table name.
  public init(column: String, in table: String, schema: String? = nil) {
    self.init(columns: CollectionOfOne(column), in: table, schema: schema)
  }

  /// Creates a region containing particular columns in a table.
  ///
  /// An empty sequence creates ``empty``. Repeated column names are ignored.
  ///
  /// - Parameters:
  ///   - columns: The columns to include.
  ///   - table: The table's name.
  ///   - schema: The table's schema, or `nil` for an unqualified table name.
  public init<Columns: Sequence>(
    columns: Columns,
    in table: String,
    schema: String? = nil
  ) where Columns.Element == String {
    let columns = Set(columns.map(\.asciiLowercased))
    guard !columns.isEmpty else {
      self.init()
      return
    }
    self.init(
      tableRegions: [TableIdentifier(schema: schema, name: table): .columns(columns)]
    )
  }

  /// Creates a region containing every column in a typed table.
  ///
  /// The region uses the table's declared `tableName` and `schemaName`. Its default query scope is
  /// not evaluated.
  ///
  /// - Parameter table: The table type.
  public init<TableType: Table>(_ table: TableType.Type) {
    self.init(table: TableType.tableName, schema: TableType.schemaName)
  }

  /// Creates a region containing a typed table column.
  ///
  /// - Parameter column: The column to include.
  public init<Column: TableColumnExpression>(_ column: Column) {
    self.init(
      column: column.name,
      in: Column.Root.tableName,
      schema: Column.Root.schemaName
    )
  }

  /// Whether the region contains no database columns.
  public var isEmpty: Bool {
    tableRegions?.isEmpty == true
  }

  /// Whether the region contains every column in the database.
  public var isFullDatabase: Bool {
    tableRegions == nil
  }

  /// Returns a region containing everything in either region.
  ///
  /// - Parameter other: The other region.
  public func union(_ other: Self) -> Self {
    guard let tableRegions, let otherTableRegions = other.tableRegions else {
      return .fullDatabase
    }

    var result = tableRegions
    for (table, otherTableRegion) in otherTableRegions {
      if let tableRegion = result[table] {
        result[table] = tableRegion.union(otherTableRegion)
      } else {
        result[table] = otherTableRegion
      }
    }
    return Self(tableRegions: result)
  }

  /// Adds everything in `other` to this region.
  ///
  /// - Parameter other: The region to add.
  public mutating func formUnion(_ other: Self) {
    self = union(other)
  }

  /// Returns a region containing only what is present in both regions.
  ///
  /// - Parameter other: The other region.
  public func intersection(_ other: Self) -> Self {
    guard let tableRegions else { return other }
    guard let otherTableRegions = other.tableRegions else { return self }

    var result: [TableIdentifier: TableRegion] = [:]
    for (table, tableRegion) in tableRegions {
      guard
        let otherTableRegion = otherTableRegions[table],
        let intersection = tableRegion.intersection(otherTableRegion)
      else { continue }
      result[table] = intersection
    }
    return Self(tableRegions: result)
  }

  /// Keeps only what is also present in `other`.
  ///
  /// - Parameter other: The region to intersect with this one.
  public mutating func formIntersection(_ other: Self) {
    self = intersection(other)
  }

  /// Returns whether this region contains all of `other`.
  ///
  /// Every region contains ``empty``, and only ``fullDatabase`` contains the full database.
  ///
  /// - Parameter other: The region whose containment is tested.
  public func contains(_ other: Self) -> Bool {
    guard let tableRegions else { return true }
    guard let otherTableRegions = other.tableRegions else { return false }

    for (table, otherTableRegion) in otherTableRegions {
      guard
        let tableRegion = tableRegions[table],
        tableRegion.contains(otherTableRegion)
      else { return false }
    }
    return true
  }

  /// Returns whether the two regions contain any of the same columns.
  ///
  /// - Parameter other: The region to compare with this one.
  public func overlaps(_ other: Self) -> Bool {
    !intersection(other).isEmpty
  }
}

extension Table {
  /// The region containing every column in this table.
  public static var databaseRegion: OrbitDatabaseRegion {
    OrbitDatabaseRegion(Self.self)
  }

  /// The region containing a declared column in this table.
  ///
  /// ```swift
  /// let titles = Reminder.databaseRegion(\.title)
  /// ```
  ///
  /// - Parameter column: A key path to the column.
  public static func databaseRegion<Column: _TableColumnExpression>(
    _ column: KeyPath<TableColumns, Column>
  ) -> OrbitDatabaseRegion {
    OrbitDatabaseRegion(
      columns: Self.columns[keyPath: column]._names,
      in: tableName,
      schema: schemaName
    )
  }

  /// The region containing declared columns in this table.
  ///
  /// ```swift
  /// let visible = Reminder.databaseRegion { ($0.title, $0.isCompleted) }
  /// ```
  ///
  /// A column group contributes all of its columns. Repeated columns are ignored.
  ///
  /// - Parameter columns: Selects one or more columns from this table's definition.
  public static func databaseRegion<each Column: _TableColumnExpression>(
    _ columns: (TableColumns) -> (repeat each Column)
  ) -> OrbitDatabaseRegion {
    var names: [String] = []
    for column in repeat each columns(Self.columns) {
      names.append(contentsOf: column._names)
    }
    return OrbitDatabaseRegion(columns: names, in: tableName, schema: schemaName)
  }

  /// The region containing every column in this instance's table.
  ///
  /// The instance's values do not narrow the region. Every instance of the same table has the
  /// same region.
  public var databaseRegion: OrbitDatabaseRegion {
    Self.databaseRegion
  }
}

extension TableColumnExpression {
  /// The region containing this column in its table.
  public var databaseRegion: OrbitDatabaseRegion {
    OrbitDatabaseRegion(self)
  }
}
