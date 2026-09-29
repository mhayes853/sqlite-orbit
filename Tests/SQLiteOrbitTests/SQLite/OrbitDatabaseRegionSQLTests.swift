#if BuiltInSQLite
  @testable import SQLiteOrbit
  import Testing

  @Suite
  struct OrbitDatabaseRegionSQLTests {
    @Test
    func discoversProjectionPredicateOrderingJoinAndCTEColumns() async throws {
      let database = try regionDatabase()

      let region = try await database.read { transaction in
        let isCompleted = false
        let query: SQL =
          """
          WITH pending AS (
            SELECT id, title
            FROM reminders
            WHERE isCompleted = \(isCompleted)
          )
          SELECT pending.title
          FROM pending
          JOIN tags ON tags.reminderID = pending.id
          ORDER BY tags.name
          """
        return try OrbitDatabaseRegion(query, in: transaction)
      }

      let expected = OrbitDatabaseRegion(
        columns: ["id", "title", "isCompleted"],
        in: "reminders"
      )
      .union(OrbitDatabaseRegion(columns: ["reminderID", "name"], in: "tags"))
      #expect(region == expected)
    }

    @Test
    func discoversStarCountAndConstantSelections() async throws {
      let database = try regionDatabase()

      try await database.read { transaction in
        let star: SQL = "SELECT * FROM reminders"
        let starRegion = try OrbitDatabaseRegion(star, in: transaction)
        #expect(
          starRegion
            == OrbitDatabaseRegion(
              columns: ["id", "title", "isCompleted", "priority"],
              in: "reminders"
            )
        )

        let count: SQL = "SELECT count(*) FROM reminders"
        let countRegion = try OrbitDatabaseRegion(count, in: transaction)
        #expect(countRegion == OrbitDatabaseRegion(table: "reminders"))

        let constant: SQL = "SELECT 1"
        let constantRegion = try OrbitDatabaseRegion(constant, in: transaction)
        let emptyRegion = try OrbitDatabaseRegion("", in: transaction)
        #expect(constantRegion == .empty)
        #expect(emptyRegion == .empty)
      }
    }

    @Test
    func discoversViewDependencies() async throws {
      let database = try regionDatabase()

      let region = try await database.read { transaction in
        let query: SQL = "SELECT title FROM pending_reminders"
        return try OrbitDatabaseRegion(query, in: transaction)
      }

      let expected = OrbitDatabaseRegion(
        columns: ["title", "isCompleted"],
        in: "reminders"
      )
      .union(OrbitDatabaseRegion(column: "title", in: "pending_reminders"))
      #expect(region == expected)
    }

    @Test
    func resolvesMainTemporaryAndAttachedSchemas() async throws {
      let database = try regionDatabase()
      try await database.write { transaction in
        try transaction.executeScript(
          """
          ATTACH DATABASE ':memory:' AS archive;
          CREATE TABLE archive.events (id INTEGER);
          CREATE TEMP TABLE scratch (id INTEGER);
          """
        )
      }

      try await database.read { transaction in
        let main: SQL = "SELECT count(*) FROM reminders"
        let mainRegion = try OrbitDatabaseRegion(main, in: transaction)
        #expect(mainRegion == OrbitDatabaseRegion(table: "reminders", schema: .main))

        let attached: SQL = "SELECT count(*) FROM events"
        let attachedRegion = try OrbitDatabaseRegion(attached, in: transaction)
        #expect(attachedRegion == OrbitDatabaseRegion(table: "events", schema: "archive"))

        let temporary: SQL = "SELECT count(*) FROM scratch"
        let temporaryRegion = try OrbitDatabaseRegion(temporary, in: transaction)
        #expect(temporaryRegion == OrbitDatabaseRegion(table: "scratch", schema: .temp))
      }
    }

    @Test
    func rejectsWritesAndRecoversAfterPreparationErrors() async throws {
      let database = try regionDatabase()

      try await database.read { transaction in
        let write: SQL = "DELETE FROM reminders"
        #expect(throws: OrbitDatabaseRegionError.writableStatement) {
          try OrbitDatabaseRegion(write, in: transaction)
        }

        let invalid: SQL = "SELECT value FROM missing"
        #expect(throws: SQLiteError.self) {
          try OrbitDatabaseRegion(invalid, in: transaction)
        }

        let valid: SQL = "SELECT title FROM reminders"
        let validRegion = try OrbitDatabaseRegion(valid, in: transaction)
        #expect(validRegion == OrbitDatabaseRegion(column: "title", in: "reminders"))
      }
    }

    @Test
    func treatsReadOnlyPragmasAsFullDatabaseReads() async throws {
      let database = try regionDatabase()

      try await database.read { transaction in
        let query: SQL = "PRAGMA table_info(reminders)"
        let region = try OrbitDatabaseRegion(query, in: transaction)
        #expect(region == .fullDatabase)
      }
    }

    @Test
    func installsTheConnectionAuthorizerOnlyOnce() async throws {
      let installationCount = Lock(0)
      let base = builtInTestLibrary
      var library = base
      library.authorizer!.install = { connection, callback, context in
        installationCount.withLock { $0 += 1 }
        return base.authorizer!.install(connection, callback, context)
      }
      let database = try regionDatabase(configuration: SQLiteConfiguration(library: library))

      try await database.read { transaction in
        let first: SQL = "SELECT title FROM reminders"
        let second: SQL = "SELECT count(*) FROM reminders"
        _ = try OrbitDatabaseRegion(first, in: transaction)
        _ = try OrbitDatabaseRegion(second, in: transaction)
      }

      #expect(installationCount.withLock { $0 } == 1)
    }

    private func regionDatabase(
      configuration: SQLiteConfiguration = .default
    ) throws -> SQLiteQueue {
      let database = try inMemoryDatabase(configuration: configuration)
      try database.writeBlocking { transaction in
        try transaction.executeScript(
          """
          CREATE TABLE reminders (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            isCompleted INTEGER NOT NULL,
            priority INTEGER NOT NULL
          );
          CREATE TABLE tags (
            id INTEGER PRIMARY KEY,
            reminderID INTEGER NOT NULL,
            name TEXT NOT NULL
          );
          CREATE VIEW pending_reminders AS
            SELECT title FROM reminders WHERE NOT isCompleted;
          """
        )
      }
      return database
    }
  }
#endif
