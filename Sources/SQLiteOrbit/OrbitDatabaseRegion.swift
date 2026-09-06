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
public struct OrbitDatabaseRegion: Hashable, Sendable, SetAlgebra {
  /// The element type used by `SetAlgebra`.
  ///
  /// Like `OptionSet`, a region's elements are themselves regions. This allows individual column,
  /// whole-table, and composite regions to be inserted and removed through the same interface.
  public typealias Element = Self

  struct TableIdentifier: Hashable, Sendable {
    let schema: SQLiteSchemaName
    let name: String

    init(schema: SQLiteSchemaName, name: String) {
      self.schema = schema
      self.name = name.asciiLowercased
    }
  }

  struct TableRegion: Hashable, Sendable {
    /// Whether a column not listed in `exceptions` belongs to the region.
    let includesUnspecifiedColumns: Bool
    /// Columns whose membership is the inverse of `includesUnspecifiedColumns`.
    let exceptions: Set<String>

    static let empty = Self(includesUnspecifiedColumns: false, exceptions: [])
    static let full = Self(includesUnspecifiedColumns: true, exceptions: [])

    static func columns(_ columns: Set<String>) -> Self {
      Self(includesUnspecifiedColumns: false, exceptions: columns)
    }

    func contains(column: String) -> Bool {
      includesUnspecifiedColumns != exceptions.contains(column)
    }

    func combining(
      _ other: Self,
      with operation: (Bool, Bool) -> Bool
    ) -> Self {
      let includesUnspecifiedColumns = operation(
        includesUnspecifiedColumns,
        other.includesUnspecifiedColumns
      )
      var exceptions: Set<String> = []
      for column in self.exceptions.union(other.exceptions) {
        if operation(contains(column: column), other.contains(column: column))
          != includesUnspecifiedColumns
        {
          exceptions.insert(column)
        }
      }
      return Self(
        includesUnspecifiedColumns: includesUnspecifiedColumns,
        exceptions: exceptions
      )
    }
  }

  /// Whether columns in a table not listed in `tableRegions` belong to the region.
  let includesUnspecifiedTables: Bool
  /// Table regions that differ from the unspecified-table default.
  let tableRegions: [TableIdentifier: TableRegion]

  init(
    includesUnspecifiedTables: Bool,
    tableRegions: [TableIdentifier: TableRegion]
  ) {
    let defaultTableRegion: TableRegion = includesUnspecifiedTables ? .full : .empty
    self.includesUnspecifiedTables = includesUnspecifiedTables
    self.tableRegions = tableRegions.filter { $0.value != defaultTableRegion }
  }

  /// The empty database region.
  public static let empty = Self()

  /// The region containing every column in the database.
  public static let fullDatabase = Self(includesUnspecifiedTables: true, tableRegions: [:])

  /// Creates the empty database region.
  public init() {
    self.init(includesUnspecifiedTables: false, tableRegions: [:])
  }

  /// Creates a region containing every column in a table.
  ///
  /// - Parameters:
  ///   - table: The table's name.
  ///   - schema: The table's schema. The default is ``SQLiteSchemaName/main``.
  public init(table: String, schema: SQLiteSchemaName = .main) {
    self.init(
      includesUnspecifiedTables: false,
      tableRegions: [TableIdentifier(schema: schema, name: table): .full]
    )
  }

  /// Creates a region containing one column in a table.
  ///
  /// - Parameters:
  ///   - column: The column's name.
  ///   - table: The table's name.
  ///   - schema: The table's schema. The default is ``SQLiteSchemaName/main``.
  public init(column: String, in table: String, schema: SQLiteSchemaName = .main) {
    self.init(columns: CollectionOfOne(column), in: table, schema: schema)
  }

  /// Creates a region containing particular columns in a table.
  ///
  /// An empty sequence creates ``empty``. Repeated column names are ignored.
  ///
  /// - Parameters:
  ///   - columns: The columns to include.
  ///   - table: The table's name.
  ///   - schema: The table's schema. The default is ``SQLiteSchemaName/main``.
  public init<Columns: Sequence>(
    columns: Columns,
    in table: String,
    schema: SQLiteSchemaName = .main
  ) where Columns.Element == String {
    let columns = Set(columns.map(\.asciiLowercased))
    guard !columns.isEmpty else {
      self.init()
      return
    }
    self.init(
      includesUnspecifiedTables: false,
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
    self.init(
      table: TableType.tableName,
      schema: TableType.schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
    )
  }

  /// Creates a region containing a typed table column.
  ///
  /// - Parameter column: The column to include.
  public init<Column: TableColumnExpression>(_ column: Column) {
    self.init(
      column: column.name,
      in: Column.Root.tableName,
      schema: Column.Root.schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
    )
  }

  /// Whether the region contains no database columns.
  public var isEmpty: Bool {
    !includesUnspecifiedTables && tableRegions.isEmpty
  }

  /// Whether the region contains every column in the database.
  public var isFullDatabase: Bool {
    includesUnspecifiedTables && tableRegions.isEmpty
  }

  private func combining(
    _ other: Self,
    with operation: (Bool, Bool) -> Bool
  ) -> Self {
    let includesUnspecifiedTables = operation(
      includesUnspecifiedTables,
      other.includesUnspecifiedTables
    )
    let defaultTableRegion: TableRegion = includesUnspecifiedTables ? .full : .empty
    let selfDefaultTableRegion: TableRegion = self.includesUnspecifiedTables ? .full : .empty
    let otherDefaultTableRegion: TableRegion = other.includesUnspecifiedTables ? .full : .empty

    var tableRegions: [TableIdentifier: TableRegion] = [:]
    for table in Set(self.tableRegions.keys).union(other.tableRegions.keys) {
      let tableRegion = (self.tableRegions[table] ?? selfDefaultTableRegion)
        .combining(
          other.tableRegions[table] ?? otherDefaultTableRegion,
          with: operation
        )
      if tableRegion != defaultTableRegion {
        tableRegions[table] = tableRegion
      }
    }
    return Self(
      includesUnspecifiedTables: includesUnspecifiedTables,
      tableRegions: tableRegions
    )
  }

  /// Returns a region containing everything in either region.
  ///
  /// - Parameter other: The other region.
  public func union(_ other: Self) -> Self {
    if self == other || other.isEmpty || isFullDatabase { return self }
    if isEmpty || other.isFullDatabase { return other }
    return combining(other, with: { $0 || $1 })
  }

  /// Adds everything in `other` to this region.
  ///
  /// - Parameter other: The region to add.
  public mutating func formUnion(_ other: Self) {
    guard self != other, !other.isEmpty, !isFullDatabase else { return }
    self = union(other)
  }

  /// Returns a region containing only what is present in both regions.
  ///
  /// - Parameter other: The other region.
  public func intersection(_ other: Self) -> Self {
    combining(other, with: { $0 && $1 })
  }

  /// Keeps only what is also present in `other`.
  ///
  /// - Parameter other: The region to intersect with this one.
  public mutating func formIntersection(_ other: Self) {
    self = intersection(other)
  }

  /// Returns a region containing everything present in exactly one of the two regions.
  ///
  /// - Parameter other: The other region.
  public func symmetricDifference(_ other: Self) -> Self {
    combining(other, with: { $0 != $1 })
  }

  /// Replaces this region with the elements present in exactly one of the two regions.
  ///
  /// - Parameter other: The other region.
  public mutating func formSymmetricDifference(_ other: Self) {
    self = symmetricDifference(other)
  }

  /// Returns a region after removing everything in `other`.
  ///
  /// The result can contain exclusions, such as every column in a table except a particular
  /// column, or every table in the database except a particular table.
  ///
  /// - Parameter other: The region to remove.
  public func subtracting(_ other: Self) -> Self {
    combining(other, with: { $0 && !$1 })
  }

  /// Removes everything in `other` from this region.
  ///
  /// - Parameter other: The region to remove.
  public mutating func subtract(_ other: Self) {
    self = subtracting(other)
  }

  /// Returns whether this region contains all of `other`.
  ///
  /// Every region contains ``empty``, and only ``fullDatabase`` contains the full database.
  ///
  /// - Parameter other: The region whose containment is tested.
  public func contains(_ other: Self) -> Bool {
    other.subtracting(self).isEmpty
  }

  /// Returns whether the two regions contain any of the same columns.
  ///
  /// - Parameter other: The region to compare with this one.
  public func overlaps(_ other: Self) -> Bool {
    !intersection(other).isEmpty
  }

  /// Inserts a region into this region.
  ///
  /// - Parameter newMember: The region to insert.
  /// - Returns: Whether any new columns were inserted, and `newMember` after insertion.
  @discardableResult
  public mutating func insert(_ newMember: Self) -> (inserted: Bool, memberAfterInsert: Self) {
    let inserted = !contains(newMember)
    formUnion(newMember)
    return (inserted, newMember)
  }

  /// Removes a region from this region.
  ///
  /// - Parameter member: The region to remove.
  /// - Returns: The portion of `member` that was present, or `nil` if it was disjoint.
  @discardableResult
  public mutating func remove(_ member: Self) -> Self? {
    let removed = intersection(member)
    guard !removed.isEmpty else { return nil }
    subtract(member)
    return removed
  }

  /// Inserts a region and returns the portion that was previously present.
  ///
  /// - Parameter newMember: The region to insert.
  /// - Returns: The portion previously present, or `nil` if the regions were disjoint.
  @discardableResult
  public mutating func update(with newMember: Self) -> Self? {
    let previous = intersection(newMember)
    formUnion(newMember)
    return previous.isEmpty ? nil : previous
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
      schema: schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
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
    return OrbitDatabaseRegion(
      columns: names,
      in: tableName,
      schema: schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
    )
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
