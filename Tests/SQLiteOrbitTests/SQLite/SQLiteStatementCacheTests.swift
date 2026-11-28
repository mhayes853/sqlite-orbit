#if BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteStatementCacheTests {
    @Test
    func readerAndWriterRefreshCachedStatementsAfterAnotherConnectionChangesTheSchema()
      async throws
    {
      try await withViewRedefinedByAnotherConnection { pool in
        let region = try await pool.read { transaction in
          // The regions are checked before the first step, which would otherwise have SQLite
          // recompile the statement and so hide what the cache handed out.
          let cursor = try transaction.cursor(
            for: currentTitles,
            cached: true,
            requiresReadOnly: true
          )
          return cursor.compiledStatement?.readRegion
        }
        #expect(region == currentTitlesRegion(over: "alternate_items"))

        let titles = try await pool.read { try $0.fetchAll(currentTitles, as: String.self) }
        #expect(titles == ["Alternate"])

        // The writer is a connection of its own, whose cached statement was just as stale.
        let writerRegion = try await pool.write { transaction in
          let cursor = try transaction.base.cursor(
            for: currentTitles,
            cached: true,
            requiresReadOnly: false
          )
          return cursor.compiledStatement?.readRegion
        }
        #expect(writerRegion == currentTitlesRegion(over: "alternate_items"))
      }
    }

    @Test
    func queryRegionFollowsASchemaChangedByAnotherConnection() async throws {
      try await withViewRedefinedByAnotherConnection { pool in
        // Deriving a region only compiles the query, so nothing earlier in the transaction has
        // made SQLite notice that its copy of the schema is out of date.
        let region = try await pool.read { transaction in
          try OrbitDatabaseRegion(currentTitles, in: transaction)
        }
        #expect(region == currentTitlesRegion(over: "alternate_items"))
      }
    }

    @Test
    func connectionRefreshesACachedStatementAfterItsOwnSchemaChange() async throws {
      try await withPooledDatabase(configuration: .default, readerCount: 1) { database in
        try await database.execute(sql: itemsSchema)
        let (region, titles) = try await database.write { transaction in
          #expect(try transaction.fetchAll(currentTitles, as: String.self) == ["Original"])
          try transaction.executeScript(redefineView)
          let cursor = try transaction.base.cursor(
            for: currentTitles,
            cached: true,
            requiresReadOnly: false
          )
          let region = cursor.compiledStatement?.readRegion
          // The same text is read through the view's new definition.
          return (region, try transaction.fetchAll(currentTitles, as: String.self))
        }
        #expect(region == currentTitlesRegion(over: "alternate_items"))
        #expect(titles == ["Alternate"])
      }
    }

    @Test
    func unchangedSchemaKeepsCachedStatements() async throws {
      try await withPooledDatabase(configuration: .default, readerCount: 1) { database in
        try await database.execute(sql: itemsSchema)
        let generation = try await database.read { transaction in
          _ = try transaction.fetchAll(currentTitles, as: String.self)
          return transaction.statements.generation
        }
        try await database.execute(sql: "INSERT INTO original_items VALUES ('Another')")
        let laterGeneration = try await database.read { transaction in
          transaction.statements.generation
        }
        #expect(laterGeneration == generation)
      }
    }

    private func withViewRedefinedByAnotherConnection(
      _ body: (SQLitePool) async throws -> Void
    ) async throws {
      try await withTestDatabaseFile("cache") { file in
        let pool = try file.pool(readerCount: 1)
        try await pool.execute(sql: itemsSchema)
        // Both of the pool's connections compile the query against the original view, so each
        // has a cached statement and a copy of the schema that the other connection makes stale.
        let titles = try await pool.read { try $0.fetchAll(currentTitles, as: String.self) }
        #expect(titles == ["Original"])
        _ = try await pool.write { try $0.fetchAll(currentTitles, as: String.self) }

        // A second connection stands in for another process, which the pool hears nothing from.
        let peer = try file.queue()
        try await peer.execute(sql: redefineView)
        try await body(pool)
      }
    }
  }

  private let itemsSchema = """
    CREATE TABLE original_items (title TEXT NOT NULL);
    CREATE TABLE alternate_items (title TEXT NOT NULL);
    INSERT INTO original_items VALUES ('Original');
    INSERT INTO alternate_items VALUES ('Alternate');
    CREATE VIEW current_items AS SELECT title FROM original_items;
    """

  private let redefineView = """
    DROP VIEW current_items;
    CREATE VIEW current_items AS SELECT title FROM alternate_items;
    """

  private let currentTitles: SQL = "SELECT title FROM current_items"

  private func currentTitlesRegion(over table: String) -> OrbitDatabaseRegion {
    OrbitDatabaseRegion(column: "title", in: table)
      .union(OrbitDatabaseRegion(column: "title", in: "current_items"))
  }
#endif
