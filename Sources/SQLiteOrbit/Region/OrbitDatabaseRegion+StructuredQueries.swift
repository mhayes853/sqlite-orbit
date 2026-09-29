#if StructuredQueries
  public import StructuredQueries

  extension OrbitDatabaseRegion {
    /// Creates a region containing every column in a typed table.
    ///
    /// The region uses the table's declared `tableName` and `schemaName`. Its default query scope is
    /// not evaluated.
    ///
    /// - Parameter table: The table type.
    public init<TableType: Table>(_ table: TableType.Type) {
      self.init(
        table: TableType.tableName,
        schema: TableType.sqliteSchemaName
      )
    }

    /// Creates a region containing a typed table column.
    ///
    /// - Parameter column: The column to include.
    public init<Column: TableColumnExpression>(_ column: Column) {
      self.init(
        column: column.name,
        in: Column.Root.tableName,
        schema: Column.Root.sqliteSchemaName
      )
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
        schema: sqliteSchemaName
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
        schema: sqliteSchemaName
      )
    }

    /// The region containing every column in this instance's table.
    ///
    /// The instance's values do not narrow the region. Every instance of the same table has the
    /// same region.
    public var databaseRegion: OrbitDatabaseRegion {
      Self.databaseRegion
    }

    /// The schema this table declares, or ``SQLiteSchemaName/main`` when it declares none.
    static var sqliteSchemaName: SQLiteSchemaName {
      schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? .main
    }
  }

  extension TableColumnExpression {
    /// The region containing this column in its table.
    public var databaseRegion: OrbitDatabaseRegion {
      OrbitDatabaseRegion(self)
    }
  }
#endif
