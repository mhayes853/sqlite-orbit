#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import SQLiteOrbit
    import Testing

    private func seededDatabase() async throws -> SQLiteQueue {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try #sql(
          "CREATE TABLE lists (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
          as: Void.self
        )
        .execute(transaction)
        try #sql(
          """
          CREATE TABLE reminders (
            id INTEGER PRIMARY KEY,
            listID INTEGER NOT NULL,
            title TEXT NOT NULL
          )
          """,
          as: Void.self
        )
        .execute(transaction)
        try List.insert {
          List(id: 1, name: "Home")
          List(id: 2, name: "Work")
        }
        .execute(transaction)
        try Reminder.insert {
          Reminder(id: 10, listID: 1, title: "Milk")
          Reminder(id: 11, listID: 1, title: "Eggs")
          Reminder(id: 12, listID: 2, title: "Standup")
        }
        .execute(transaction)
      }
      return database
    }

    @Test
    func joinedSelectsDecodeEveryTableInTheRowEagerlyAndLazily() async throws {
      let database = try await seededDatabase()

      let joined = try await database.read { transaction in
        try Reminder.join(List.all) { $0.listID.eq($1.id) }.order { reminder, _ in reminder.id }
          .fetchAll(transaction)
      }

      #expect(joined.count == 3)
      #expect(joined[0].0 == Reminder(id: 10, listID: 1, title: "Milk"))
      #expect(joined[0].1 == List(id: 1, name: "Home"))
      #expect(joined[2].0 == Reminder(id: 12, listID: 2, title: "Standup"))
      #expect(joined[2].1 == List(id: 2, name: "Work"))

      let first = try await database.read { transaction in
        try Reminder.join(List.all) { $0.listID.eq($1.id) }.order { reminder, _ in reminder.id }
          .fetchOne(transaction)
      }
      #expect(first?.0 == Reminder(id: 10, listID: 1, title: "Milk"))
      #expect(first?.1 == List(id: 1, name: "Home"))

      let titles = try await database.read { transaction in
        var cursor = try Reminder.join(List.all) { $0.listID.eq($1.id) }
          .order { reminder, _ in reminder.id }.fetchCursor(transaction)
        var titles: [String] = []
        while let row = try cursor.next() {
          titles.append("\(row.1.name): \(row.0.title)")
        }
        return titles
      }

      #expect(titles == ["Home: Milk", "Home: Eggs", "Work: Standup"])
    }

    @Test
    func compoundSelectsAreClassifiedByTheirProtocol() async throws {
      let database = try await seededDatabase()

      // `union` returns a statement whose concrete type the query library keeps private, so it could
      // never have been named by a conformance list.
      let ids = try await database.read { transaction in
        try Reminder.where { $0.id.eq(10) }.select(\.id)
          .union(Reminder.where { $0.id.eq(12) }.select(\.id)).fetchAll(transaction)
      }

      #expect(ids.sorted() == [10, 12])
    }

    @Test
    func selectStatementsReportTheirCount() async throws {
      let database = try await seededDatabase()

      let all = try await database.read { transaction in
        try Reminder.all.fetchCount(transaction)
      }
      let filtered = try await database.read { transaction in
        try Reminder.where { $0.listID.eq(1) }.fetchCount(transaction)
      }

      #expect(all == 3)
      #expect(filtered == 2)
    }

    @Test
    func findLooksUpByPrimaryKeyAndReportsMisses() async throws {
      let database = try await seededDatabase()

      let found = try await database.read { transaction in
        try Reminder.all.find(transaction, key: 11)
      }
      #expect(found == Reminder(id: 11, listID: 1, title: "Eggs"))

      await #expect(throws: OrbitDatabaseRecordNotFoundError.self) {
        try await database.read { transaction in
          try Reminder.all.find(transaction, key: 99)
        }
      }
    }

    @Test
    func writeTransactionsRunReadsAndTemporaryTriggers() async throws {
      let database = try await seededDatabase()

      let count = try await database.write { transaction in
        // A temporary trigger is a statement, not a select, so only a write transaction takes it.
        try Reminder.createTemporaryTrigger(
          after: .insert { _ in
            List.update { $0.name = "touched" }.where { $0.id.eq(1) }
          }
        )
        .execute(transaction)
        try Reminder.insert { Reminder(id: 13, listID: 1, title: "Bread") }.execute(transaction)
        // Reads are available inside a write transaction by refinement.
        return try Reminder.all.fetchCount(transaction)
      }

      #expect(count == 4)

      let touched = try await database.read { transaction in
        try List.where { $0.id.eq(1) }.select(\.name).fetchOne(transaction)
      }
      #expect(touched == "touched")
    }

    @Test
    func writeStatementsReturnRows() async throws {
      let database = try await seededDatabase()

      let titles = try await database.write { transaction in
        try Reminder.update { $0.title = $0.title.upper() }
          .where { $0.listID.eq(1) }
          .returning(\.title).fetchAll(transaction)
      }

      #expect(titles.sorted() == ["EGGS", "MILK"])
    }

    @Test
    func valuesStatementsDecodeThroughTheGenericPath() async throws {
      let database = try await seededDatabase()

      // `Values` records per-element decoding metadata that swift-structured-queries keeps behind
      // 'package' access, so this package cannot reach it. Decoding against the statement's static
      // types instead agrees for every shape reachable here, including rows that mix a table value
      // with a scalar, so no special case is needed. These cases pin that down.
      let pairs: [(Int, String)] = try await database.read { transaction in
        try Values {
          (1, "one")
          (2, "two")
        }
        .fetchAll(transaction)
      }
      #expect(pairs.map(\.0) == [1, 2])
      #expect(pairs.map(\.1) == ["one", "two"])

      let mixed: [(List, Int)] = try await database.read { transaction in
        try Values { (List(id: 7, name: "Ad hoc"), 5) }.fetchAll(transaction)
      }
      #expect(mixed.count == 1)
      #expect(mixed[0].0 == List(id: 7, name: "Ad hoc"))
      #expect(mixed[0].1 == 5)
    }

    @Test
    func eagerFetchesRebindTheCachedStatementEveryTime() async throws {
      let database = try await seededDatabase()

      // Eager fetches share one prepared statement per SQL string on a connection. Each fetch must
      // start that statement over with its own bindings rather than resume where the last left off.
      let titles = try await database.read { transaction in
        try (10...12)
          .map { id in
            try Reminder.where { $0.id.eq(id) }.select(\.title).fetchOne(transaction)
          }
      }
      #expect(titles == ["Milk", "Eggs", "Standup"])

      let counts = try await database.read { transaction in
        try [1, 2, 1]
          .map { listID in
            try Reminder.where { $0.listID.eq(listID) }.select(\.id).fetchAll(transaction).count
          }
      }
      #expect(counts == [2, 1, 2])

      // The same holds for writes that return rows.
      let inserted = try await database.write { transaction in
        try (20...22)
          .map { id in
            try Reminder.insert { Reminder(id: id, listID: 2, title: "Task \(id)") }.returning(\.id)
              .fetchOne(transaction)
          }
      }
      #expect(inserted == [20, 21, 22])
    }

    @Test
    func statementsThatBuildNoSQLAreRunnable() async throws {
      let database = try await seededDatabase()

      // `Values` with no rows builds an empty fragment, which SQLite cannot prepare.
      let noRows: [(Int, String)] = []
      let empty: [(Int, String)] = try await database.read { transaction in
        try Values {
          for row in noRows {
            row
          }
        }
        .fetchAll(transaction)
      }
      #expect(empty.isEmpty)

      // An insert of nothing builds no SQL, so it runs nothing rather than failing to compile an
      // empty statement.
      try await database.write { transaction in
        let noReminders: [Reminder] = []
        try Reminder.insert {
          for reminder in noReminders {
            reminder
          }
        }
        .execute(transaction)
      }

      // The empty write must not have disturbed the table.
      let count = try await database.read { transaction in
        try Reminder.all.fetchCount(transaction)
      }
      #expect(count == 3)
    }

    @Table("lists")
    private struct List: Equatable, Sendable {
      let id: Int
      var name: String
    }

    @Table("reminders")
    private struct Reminder: Equatable, Sendable {
      let id: Int
      var listID: Int
      var title: String
    }
  #endif
#endif
