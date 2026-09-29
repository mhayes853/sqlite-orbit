#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Foundation
    import StructuredQueries
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
              for: SQL(fragment: currentTitles.query),
              cached: true,
              requiresReadOnly: true
            )
            return cursor.preparedStatement.readRegion
          }
          #expect(region == currentTitlesRegion(over: "alternate_items"))

          let titles = try await pool.read { try $0.fetchAll(currentTitles) }
          #expect(titles == ["Alternate"])

          // The writer is a connection of its own, whose cached statement was just as stale.
          let writerRegion = try await pool.write { transaction in
            let cursor = try transaction.base.cursor(
              for: SQL(fragment: currentTitles.query),
              cached: true,
              requiresReadOnly: false
            )
            return cursor.preparedStatement.readRegion
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
            try OrbitDatabaseRegion(SQL(fragment: currentTitles.query), in: transaction)
          }
          #expect(region == currentTitlesRegion(over: "alternate_items"))
        }
      }

      @Test
      func connectionRefreshesACachedStatementAfterItsOwnSchemaChange() async throws {
        try await withPooledDatabase(configuration: .default, maximumReaderCount: 1) { database in
          try await database.write { transaction in
            try transaction.executeScript(itemsSchema)
          }
          let region = try await database.write { transaction in
            _ = try transaction.fetchAll(currentTitles)
            try transaction.executeScript(
              """
              DROP VIEW current_items;
              CREATE VIEW current_items AS SELECT title FROM alternate_items;
              """
            )
            let cursor = try transaction.base.cursor(
              for: SQL(fragment: currentTitles.query),
              cached: true,
              requiresReadOnly: false
            )
            return cursor.preparedStatement.readRegion
          }
          #expect(region == currentTitlesRegion(over: "alternate_items"))
        }
      }

      @Test
      func unchangedSchemaKeepsCachedStatements() async throws {
        try await withPooledDatabase(configuration: .default, maximumReaderCount: 1) { database in
          try await database.write { transaction in
            try transaction.executeScript(itemsSchema)
          }
          let generation = try await database.read { transaction in
            _ = try transaction.fetchAll(currentTitles)
            return transaction.statements.generation
          }
          try await database.write { transaction in
            try transaction.execute("INSERT INTO original_items VALUES ('Another')")
          }
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
          var configuration = SQLiteConfiguration.default
          configuration.readerCount = 1
          let pool = try file.pool(configuration: configuration)
          try await pool.write { transaction in
            try transaction.executeScript(itemsSchema)
          }
          // Both of the pool's connections compile the query against the original view, so each has
          // a cached statement and a copy of the schema that the other connection makes stale.
          let titles = try await pool.read { try $0.fetchAll(currentTitles) }
          #expect(titles == ["Original"])
          _ = try await pool.write { try $0.fetchAll(currentTitles) }

          // A second connection stands in for another process, which the pool hears nothing from.
          let peer = try file.queue()
          try await peer.write { transaction in
            try transaction.executeScript(
              """
              DROP VIEW current_items;
              CREATE VIEW current_items AS SELECT title FROM alternate_items;
              """
            )
          }
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

    private let currentTitles = #sql("SELECT title FROM current_items", as: String.self)

    private func currentTitlesRegion(over table: String) -> OrbitDatabaseRegion {
      OrbitDatabaseRegion(column: "title", in: table)
        .union(OrbitDatabaseRegion(column: "title", in: "current_items"))
    }
  #endif
#endif
