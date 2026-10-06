#if StructuredQueries
  import StructuredQueriesSQLite

  struct OrbitFetchAllStatementRequest<QueryValue: QueryRepresentable>: OrbitFetchKeyRequest
  where QueryValue.QueryOutput: Sendable {
    let request: OrbitStatementRequest<[QueryValue.QueryOutput]>

    init(statement: some Statement<QueryValue>) { request = statement.allRowsRequest() }

    func fetch(_ transaction: borrowing SQLiteReadTransaction) throws
      -> OrbitFetchSectionCollection<QueryValue.QueryOutput, String?>
    {
      OrbitFetchSectionCollection(elements: try request.fetch(transaction), sectionName: nil)
    }
  }
#endif
