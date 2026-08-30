#if SQLiteCrossStructuredQueries
  import SQLiteCross
  import StructuredQueries

  extension DatabaseChangeRegion {
    /// Creates a change region for a table declared with swift-structured-queries.
    public static func table<TableType: Table>(_ table: TableType.Type) -> Self {
      .tables([TableType.tableName])
    }
  }
#endif
