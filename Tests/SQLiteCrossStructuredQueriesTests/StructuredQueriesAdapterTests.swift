#if SQLiteCrossStructuredQueries
  import SQLiteCross
  import SQLiteCrossStructuredQueries
  import StructuredQueries
  import Testing

  @Test
  func structuredQueriesTablesCanDescribeChangeRegions() {
    #expect(DatabaseChangeRegion.table(Item.self) == .tables(["item"]))
  }

  @Table("item") private struct Item {
    let id: Int
  }
#endif
