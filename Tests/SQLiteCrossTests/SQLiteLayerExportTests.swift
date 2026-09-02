// Deliberately imports only 'SQLiteCross': this asserts that the SQLite query-building layer is
// re-exported, and covers a 'RETURNING' statement, which lives in StructuredQueriesSQLiteCore.
#if GRDB
  import GRDB
  import SQLiteCross
  import Testing

  @Test
  func sqliteQueryLayerIsReachableThroughSQLiteCrossAlone() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )

    try await database.write { transaction in
      _ = try transaction.execute(
        #sql(
          "CREATE TABLE probes (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
          as: Void.self
        )
      )
    }

    let ids = try await database.write { transaction in
      try transaction.fetchAll(Probe.insert { Probe(id: 1, n: 5) }.returning(\.id))
    }

    #expect(ids == [1])
  }

  @Table
  private struct Probe: Equatable, Sendable {
    let id: Int
    var n: Int
  }
#endif
