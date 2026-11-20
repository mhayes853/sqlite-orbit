#if StructuredQueries && BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  #if SystemSQLite
    import CSQLite3
  #endif

  // A prepared insert builds its SQL and binds its values itself rather than through the query
  // builder, so the oracle tests hold it to what `Table.insert` runs for the same rows: the same
  // statement with the same values bound, and the same rows written. The rest cover what the query
  // builder has no say in: conflict clauses, rowids, counts, bulk atomicity and the conveniences.
  @Suite
  struct SQLitePreparedInsertTests {
    // MARK: - Oracle

    @Test
    func recordInsertsRunWhatTheQueryBuilderRuns() async throws {
      try expectSameInserts(
        everything,
        schema: everythingSchema,
        table: "everything",
        structuredQueries: { row in Everything.insert { row } },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Everything.self)
          try insert.execute(row)
        }
      )
    }

    @Test
    func draftInsertsRunWhatTheQueryBuilderRuns() async throws {
      let drafts =
        everything.map(Everything.Draft.init) + [Everything.Draft(everything[0], id: nil)]
      try expectSameInserts(
        drafts,
        schema: everythingSchema,
        table: "everything",
        structuredQueries: { row in Everything.insert { row } },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Everything.Draft.self)
          try insert.execute(row)
        }
      )
    }

    @Test
    func upsertsRunWhatTheQueryBuilderRuns() async throws {
      try expectSameInserts(
        everything,
        schema: everythingSchema,
        table: "everything",
        structuredQueries: { row in Everything.upsert { row } },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Everything.self, onConflict: .update)
          try insert.execute(row)
        }
      )
      try expectSameInserts(
        everything.map(Everything.Draft.init),
        schema: everythingSchema,
        table: "everything",
        structuredQueries: { row in Everything.upsert { row } },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Everything.Draft.self, onConflict: .update)
          try insert.execute(row)
        }
      )
    }

    @Test
    func columnGroupsGeneratedColumnsAndSchemasRunWhatTheQueryBuilderRuns() async throws {
      let places = [
        Place(id: 1, name: "Home", coordinates: Coordinates(latitude: 1.5, longitude: -2.25)),
        Place(id: 2, name: "Work", coordinates: Coordinates(latitude: 0, longitude: 0))
      ]
      try expectSameInserts(
        places,
        schema: "CREATE TABLE places (id INTEGER PRIMARY KEY, name, latitude, longitude)",
        table: "places",
        structuredQueries: { row in Place.insert { row } },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Place.self)
          try insert.execute(row)
        }
      )
      // Turso only compiles generated columns behind an experimental flag.
      #if !Turso
        try expectSameInserts(
          [
            Person.Draft(first: "Ada", last: "Lovelace"), Person.Draft(id: 7, first: "A", last: "B")
          ],
          schema: """
            CREATE TABLE people (
              id INTEGER PRIMARY KEY,
              first TEXT NOT NULL,
              last TEXT NOT NULL,
              initials TEXT GENERATED ALWAYS AS (substr(first, 1, 1) || substr(last, 1, 1)) STORED
            )
            """,
          table: "people",
          structuredQueries: { row in Person.insert { row } },
          plan: { transaction, row in
            var insert = try transaction.prepareInsert(Person.Draft.self)
            try insert.execute(row)
          }
        )
      #endif
      try expectSameInserts(
        [Archived(id: 1, name: "Old"), Archived(id: 2, name: "Older")],
        schema: """
          ATTACH DATABASE ':memory:' AS archive;
          CREATE TABLE archive.archived (id INTEGER PRIMARY KEY, name);
          """,
        table: "archive.archived",
        structuredQueries: { row in Archived.insert { row } },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Archived.self)
          try insert.execute(row)
        }
      )
    }

    @Test
    func partialInsertsRunWhatTheQueryBuilderRuns() async throws {
      let rows = everything.map { ($0.text, $0.date, $0.uuidBytes, $0.optionalPriority, $0.tags) }
      try expectSameInserts(
        rows,
        schema: everythingSchema,
        table: "everything",
        structuredQueries: { row in
          Everything.insert {
            ($0.text, $0.date, $0.uuidBytes, $0.optionalPriority, $0.tags)
          } values: {
            (row.0, row.1, row.2, row.3, row.4)
          }
        },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Everything.self) {
            ($0.text, $0.date, $0.uuidBytes, $0.optionalPriority, $0.tags)
          }
          try insert.execute(row.0, row.1, row.2, row.3, row.4)
        }
      )
      try expectSameInserts(
        ["one", "two"],
        schema: everythingSchema,
        table: "everything",
        structuredQueries: { row in
          Everything.insert {
            $0.text
          } values: {
            row
          }
        },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Everything.self) { $0.text }
          try insert.execute(row)
        }
      )
      let places = [("Home", Coordinates(latitude: 1, longitude: 2))]
      try expectSameInserts(
        places,
        schema: "CREATE TABLE places (id INTEGER PRIMARY KEY, name, latitude, longitude)",
        table: "places",
        structuredQueries: { row in
          Place.insert {
            ($0.name, $0.coordinates)
          } values: {
            (row.0, row.1)
          }
        },
        plan: { transaction, row in
          var insert = try transaction.prepareInsert(Place.self) { ($0.name, $0.coordinates) }
          try insert.execute(row.0, row.1)
        }
      )
    }

    @Test
    func partialUpsertsUpdateOnlyTheListedColumns() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        try transaction.insert(Reminder(id: 1, title: "Milk", listID: 1, code: "m"))
        var rename = try transaction.prepareInsert(Reminder.self, onConflict: .update) {
          ($0.id, $0.title)
        }
        #expect(
          rename.sql == """
            INSERT INTO "reminders" ("id", "title") VALUES (?, ?) \
            ON CONFLICT ("id") DO UPDATE SET "title" = "excluded"."title"
            """
        )
        #expect(try rename.execute(1, "Oat milk") == nil)
        // A row without a conflict is inserted, with the columns left out at their defaults.
        #expect(try rename.execute(2, "Tea") == 2)
      }
      let rows = try await database.read { try Reminder.all.order(by: \.id).fetchAll($0) }
      #expect(
        rows == [
          Reminder(id: 1, title: "Oat milk", listID: 1, code: "m"),
          Reminder(id: 2, title: "Tea", listID: 0)
        ]
      )
    }

    // MARK: - Conflicts

    @Test
    func ignoreSkipsConflictsButNotOtherConstraints() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        var insert = try transaction.prepareInsert(Tag.self, onConflict: .ignore)
        #expect(
          insert.sql == #"INSERT INTO "tags" ("id", "title") VALUES (?, ?) ON CONFLICT DO NOTHING"#
        )
        #expect(try insert.execute(Tag(id: 1, title: "home")) == 1)
        // The same key, and another row with the same unique title, are both skipped.
        #expect(try insert.execute(Tag(id: 1, title: "work")) == nil)
        #expect(try insert.execute(Tag(id: 2, title: "home")) == nil)
        #expect(try insert.execute(Tag(id: 2, title: "work")) == 2)

        var notes = try transaction.prepareInsert(Note.self, onConflict: .ignore)
        #expect(throws: SQLiteError.self) { try notes.execute(Note(id: 1, body: nil)) }
      }
      let tags = try await database.read { try Tag.all.order(by: \.id).fetchAll($0) }
      #expect(tags == [Tag(id: 1, title: "home"), Tag(id: 2, title: "work")])
    }

    @Test
    func updateWritesTheNewValuesAndDraftsWithoutAKeyInsert() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        var save = try transaction.prepareInsert(Reminder.self, onConflict: .update)
        #expect(try save.execute(Reminder(id: 1, title: "Milk", listID: 1)) == 1)
        #expect(
          try save.execute(Reminder(id: 1, title: "Eggs", listID: 2, isCompleted: true)) == nil
        )

        var drafts = try transaction.prepareInsert(Reminder.Draft.self, onConflict: .update)
        #expect(try drafts.execute(Reminder.Draft(title: "Bread", listID: 1)) == 2)
        #expect(try drafts.execute(Reminder.Draft(id: 2, title: "Rye", listID: 1)) == nil)

        // Writing nothing but the key leaves a conflicting row as it is.
        try transaction.insert(Mark(id: 1, label: "kept"))
        var keys = try transaction.prepareInsert(Mark.self, onConflict: .update) { $0.id }
        #expect(keys.sql.hasSuffix(#"ON CONFLICT ("id") DO NOTHING"#))
        #expect(try keys.execute(1) == nil)
        #expect(transaction.changesCount == 0)
        #expect(try keys.execute(2) == 2)
        #expect(
          try Mark.all.order(by: \.id).fetchAll(transaction) == [
            Mark(id: 1, label: "kept"), Mark(id: 2, label: nil)
          ]
        )
      }
      let rows = try await database.read { try Reminder.all.order(by: \.id).fetchAll($0) }
      #expect(
        rows == [
          Reminder(id: 1, title: "Eggs", listID: 2, isCompleted: true),
          Reminder(id: 2, title: "Rye", listID: 1)
        ]
      )
    }

    @Test
    func aPartialUpdateMustWriteThePrimaryKey() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        let error = #expect(throws: SQLiteError.self) {
          try prepareTitleUpsert(transaction)
        }
        #expect(error?.code == .misuse)
      }
    }

    @Test
    func replaceDeletesConflictingRowsAndTheirCascadedChildren() async throws {
      let database = try await remindersDatabase()
      let recorder = TransactionEventRecorder()
      try await database.write { transaction in
        try transaction.insert(contentsOf: [
          Reminder(id: 1, title: "Milk", listID: 1, code: "a"),
          Reminder(id: 2, title: "Eggs", listID: 2, code: "b")
        ])
        try transaction.insert(Child(id: 1, reminderID: 1))
      }
      let subscription = try database.subscribe(transactionObserver: recorder)
      try await database.write { transaction in
        var replace = try transaction.prepareInsert(Reminder.self, onConflict: .replace)
        #expect(replace.sql.hasPrefix(#"INSERT OR REPLACE INTO "reminders""#))
        // Conflicts with row 2 on its key and with row 1 on its unique code, so both go, and row
        // 1's child goes with it.
        #expect(try replace.execute(Reminder(id: 2, title: "Bread", listID: 1, code: "a")) == 2)
        #expect(transaction.changesCount == 1)
      }
      _ = subscription
      let (reminders, children) = try await database.read { transaction in
        (try Reminder.all.fetchAll(transaction), try Child.all.fetchAll(transaction))
      }
      #expect(reminders == [Reminder(id: 2, title: "Bread", listID: 1, code: "a")])
      #expect(children.isEmpty)
      let changed = recorder.changedRegions.reduce(OrbitDatabaseRegion.empty) { $0.union($1) }
      #expect(changed.contains(OrbitDatabaseRegion(table: "children")))
      #expect(changed.contains(OrbitDatabaseRegion(table: "reminders")))
    }

    // MARK: - Rowids and counts

    // A build without `sqlite3_set_last_insert_rowid`, such as Turso, compares the rowid before
    // and after each run instead, which tells these runs apart all the same.
    @Test(arguments: [true, false])
    func runsReturnRowidsAndLeaveTheLastRowidAsSQLiteWould(canSetRowid: Bool) async throws {
      let database = try await remindersDatabase(canSetRowid: canSetRowid)
      try await database.write { transaction in
        var insert = try transaction.prepareInsert(Reminder.Draft.self)
        #expect(try insert.execute(Reminder.Draft(title: "Milk", listID: 1)) == 1)
        #expect(try insert.execute(Reminder.Draft(id: 10, title: "Eggs", listID: 1)) == 10)
        #expect(transaction.lastInsertedRowID == 10)

        var ignore = try transaction.prepareInsert(Reminder.self, onConflict: .ignore)
        #expect(try ignore.execute(Reminder(id: 1, title: "Again", listID: 1)) == nil)
        #expect(transaction.lastInsertedRowID == 10)
        #expect(transaction.changesCount == 0)

        var update = try transaction.prepareInsert(Reminder.self, onConflict: .update)
        #expect(try update.execute(Reminder(id: 1, title: "Updated", listID: 1)) == nil)
        #expect(transaction.lastInsertedRowID == 10)
        #expect(transaction.changesCount == 1)
        #expect(try update.execute(Reminder(id: 5, title: "New", listID: 1)) == 5)
        #expect(transaction.lastInsertedRowID == 5)

        // A failed run leaves the last rowid as it was too.
        var notes = try transaction.prepareInsert(Note.self, onConflict: .ignore)
        #expect(throws: SQLiteError.self) { try notes.execute(Note(id: 3, body: nil)) }
        #expect(transaction.lastInsertedRowID == 5)
      }
    }

    @Test
    func bulkRunsCountWhatTheyInsertOrUpdate() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        let rows = (1...3).map { Reminder(id: $0, title: "\($0)", listID: 1, code: "\($0)") }
        var insert = try transaction.prepareInsert(Reminder.self)
        #expect(try insert.execute(contentsOf: rows) == 3)

        var ignore = try transaction.prepareInsert(Reminder.self, onConflict: .ignore)
        let more = (2...5).map { Reminder(id: $0, title: "\($0)", listID: 1) }
        #expect(try ignore.execute(contentsOf: more) == 2)

        var update = try transaction.prepareInsert(Reminder.self, onConflict: .update)
        let changed = (4...6).map { Reminder(id: $0, title: "new \($0)", listID: 2) }
        #expect(try update.execute(contentsOf: changed) == 3)

        // The row replaced on its code is deleted, which is not counted.
        var replace = try transaction.prepareInsert(Reminder.self, onConflict: .replace)
        let replacing = [
          Reminder(id: 7, title: "7", listID: 1, code: "1"),
          Reminder(id: 2, title: "two", listID: 1)
        ]
        #expect(try replace.execute(contentsOf: replacing) == 2)

        var add = try transaction.prepareInsert(Reminder.self) { ($0.title, $0.listID) }
        #expect(try add.execute(contentsOf: [("Eggs", 1), ("Bread", 2)]) == 2)
        #expect(try add.execute("Buy milk", 1) == 10)
      }
      let count = try await database.read { try Reminder.all.fetchCount($0) }
      #expect(count == 9)
    }

    // MARK: - Bulk atomicity

    @Test
    func aFailedBulkRunLeavesNoneOfItsRowsAndKeepsEarlierOnes() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        try transaction.insert(Reminder(id: 1, title: "Kept", listID: 1))
        var insert = try transaction.prepareInsert(Reminder.self)
        let failing = [2, 3, 1, 4].map { Reminder(id: $0, title: "\($0)", listID: 1) }
        #expect(throws: SQLiteError.self) { try insert.execute(contentsOf: failing) }
        #expect(throws: SQLiteError.self) { try transaction.insert(contentsOf: failing) }
        // A row that breaks a constraint the conflict clause does not skip fails the run too.
        let notes = [Note(id: 1, body: "a"), Note(id: 2, body: nil), Note(id: 3, body: "c")]
        #expect(throws: SQLiteError.self) {
          try transaction.insert(contentsOf: notes.lazy.map { $0 }, onConflict: .ignore)
        }
        #expect(try Note.all.fetchCount(transaction) == 0)
        // Runs that succeed afterwards are kept, as is everything before the failure.
        #expect(try insert.execute(contentsOf: EmptyCollection()) == 0)
        #expect(
          try insert.execute(contentsOf: CollectionOfOne(Reminder(id: 5, title: "5", listID: 1)))
            == 1
        )
        #expect(
          try insert.execute(
            contentsOf: (6...7).lazy.map { Reminder(id: $0, title: "\($0)", listID: 1) }
          ) == 2
        )
      }
      let ids = try await database.read { try Reminder.all.order(by: \.id).fetchAll($0).map(\.id) }
      #expect(ids == [1, 5, 6, 7])
    }

    @Test
    func bulkRunsNestInsideTheCallersSavepoints() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        try transaction.execute("SAVEPOINT outer")
        try transaction.insert(Reminder(id: 1, title: "1", listID: 1))
        let failing = [2, 1].map { Reminder(id: $0, title: "\($0)", listID: 1) }
        #expect(throws: SQLiteError.self) { try transaction.insert(contentsOf: failing) }
        try transaction.insert(
          contentsOf: [3, 4].map { Reminder(id: $0, title: "\($0)", listID: 1) }
        )
        try transaction.execute("RELEASE outer")

        try transaction.execute("SAVEPOINT discarded")
        try transaction.insert(
          contentsOf: [5, 6].map { Reminder(id: $0, title: "\($0)", listID: 1) }
        )
        try transaction.execute("ROLLBACK TO discarded")
        try transaction.execute("RELEASE discarded")
      }
      let ids = try await database.read { try Reminder.all.order(by: \.id).fetchAll($0).map(\.id) }
      #expect(ids == [1, 3, 4])
    }

    // MARK: - Conveniences

    @Test
    func conveniencesInsertWithEachConflictClause() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        // Each result is bound before it is checked, since `#expect` cannot see a call on the
        // borrowed transaction through.
        let milk = try transaction.insert(Reminder.Draft(title: "Milk", listID: 1))
        let eggs = try transaction.insert(Reminder(id: 2, title: "Eggs", listID: 1, code: "e"))
        let skipped = try transaction.insert(
          Reminder(id: 2, title: "Skip", listID: 1),
          onConflict: .ignore
        )
        let updated = try transaction.insert(
          Reminder(id: 2, title: "Eggs!", listID: 1, code: "e"),
          onConflict: .update
        )
        // Conflicts with row 2 on its code, which deletes it.
        let replaced = try transaction.insert(
          Reminder(id: 3, title: "Bread", listID: 1, code: "e"),
          onConflict: .replace
        )
        let draftUpdated = try transaction.insert(
          Reminder.Draft(id: 3, title: "Rye", listID: 1),
          onConflict: .update
        )
        let rowIDs = [milk, eggs, replaced]
        #expect(rowIDs == [1, 2, 3])
        let skippedRowIDs = [skipped, updated, draftUpdated]
        #expect(skippedRowIDs == [nil, nil, nil])
        #expect(throws: SQLiteError.self) {
          try transaction.insert(Reminder(id: 1, title: "Dup", listID: 1))
        }

        let rows = (4...5).map { Reminder(id: $0, title: "\($0)", listID: 1) }
        let inserted = try transaction.insert(contentsOf: rows)
        let ignored = try transaction.insert(contentsOf: rows, onConflict: .ignore)
        let upserted = try transaction.insert(contentsOf: rows, onConflict: .update)
        let replacedRows = try transaction.insert(contentsOf: rows, onConflict: .replace)
        let counts = [inserted, ignored, upserted, replacedRows]
        #expect(counts == [2, 0, 2, 2])
      }
      let titles = try await database.read {
        try Reminder.all.order(by: \.id).fetchAll($0).map(\.title)
      }
      #expect(titles == ["Milk", "Rye", "4", "5"])
    }

    @Test
    func conveniencesReuseOnePlanPerTableAndConflictClause() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        let first = try transaction.prepareInsert(Reminder.self).sql
        let second = try transaction.prepareInsert(Reminder.self).sql
        #expect(first.isIdentical(to: second))
        let upsert = try transaction.prepareInsert(Reminder.self, onConflict: .update).sql
        #expect(!upsert.isIdentical(to: first))
        #expect(
          upsert.isIdentical(
            to: try transaction.prepareInsert(Reminder.self, onConflict: .update).sql
          )
        )
        #expect(try transaction.prepareInsert(Reminder.self, onConflict: .ignore).sql != upsert)
        #expect(try transaction.prepareInsert(Reminder.self, onConflict: .replace).sql != first)
      }
    }

    @Test
    func theUsageExampleCompiles() async throws {
      let database = try await remindersDatabase()
      let reminders = [Reminder(id: 10, title: "Milk", listID: 1)]
      let drafts = [Reminder.Draft(title: "Eggs", listID: 1)]
      let incoming = [Reminder(id: 10, title: "Milk!", listID: 1)].map(Reminder.Draft.init)
      try await database.write { transaction in
        let listID = 1
        let id = try transaction.insert(Reminder.Draft(title: "Tea", listID: listID))
        try transaction.insert(contentsOf: reminders)
        try transaction.insert(Tag(id: 1, title: "home"), onConflict: .ignore)
        var insert = try transaction.prepareInsert(Reminder.Draft.self)
        for draft in drafts { try insert.execute(draft) }
        var save = try transaction.prepareInsert(Reminder.self, onConflict: .update)
        try save.execute(
          contentsOf: incoming.lazy.map { Reminder(id: $0.id!, title: $0.title, listID: $0.listID) }
        )
        var add = try transaction.prepareInsert(Reminder.self) { ($0.title, $0.listID) }
        try add.execute("Buy milk", listID)
        try add.execute(contentsOf: [("Eggs", listID), ("Bread", listID)])
        var rename = try transaction.prepareInsert(Reminder.self, onConflict: .update) {
          ($0.id, $0.title)
        }
        try rename.execute(Int(id), "Buy oat milk")
      }
    }
  }

  // MARK: - Helpers

  private func prepareTitleUpsert(_ transaction: borrowing SQLiteWriteTransaction) throws {
    var upsert = try transaction.prepareInsert(Reminder.self, onConflict: .update) { $0.title }
    try upsert.execute("Unreachable")
  }

  private func remindersDatabase(canSetRowid: Bool = true) async throws -> SQLiteQueue {
    var configuration = SQLiteConfiguration.default
    configuration.isForeignKeysEnabled = true
    if !canSetRowid {
      configuration.library.connections.setLastInsertedRowID = nil
    }
    let database = try inMemoryDatabase(configuration: configuration)
    try await database.write { transaction in
      try transaction.executeScript(
        """
        CREATE TABLE reminders (
          id INTEGER PRIMARY KEY,
          title TEXT NOT NULL,
          listID INTEGER NOT NULL DEFAULT 0,
          isCompleted INTEGER NOT NULL DEFAULT 0,
          code TEXT UNIQUE
        );
        CREATE TABLE children (
          id INTEGER PRIMARY KEY,
          reminderID INTEGER NOT NULL REFERENCES reminders (id) ON DELETE CASCADE
        );
        CREATE TABLE tags (id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE);
        CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL);
        CREATE TABLE marks (id INTEGER PRIMARY KEY, label TEXT);
        """
      )
    }
    return database
  }

  // Runs each row through the plan and through the query builder in turn, on a fresh table, and
  // expects the same statement to have run, with the same values, and the same rows written.
  private func expectSameInserts<Row, Insert: Statement>(
    _ rows: [Row],
    schema: String,
    table: String,
    structuredQueries: (Row) -> Insert,
    plan: (borrowing SQLiteWriteTransaction, Row) throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
    try owner.write { try $0.executeScript(schema) }
    for row in rows {
      let fragment = structuredQueries(row).query
      let (planned, built) = try owner.write { transaction in
        let select: SQL = "SELECT * FROM \(raw: table) ORDER BY rowid"
        func written(_ transaction: borrowing SQLiteWriteTransaction) throws
          -> [[OrbitDatabaseValue]]
        {
          try transaction.fetchAll(select) { row in (0..<row.columnCount).map { row[$0] } }
        }
        let trace = StatementTrace(transaction.sqliteConnection)
        try plan(transaction, row)
        let planned = (trace.inserts, try written(transaction))
        try transaction.execute("DELETE FROM \(raw: table)")
        trace.inserts.removeAll()
        try transaction.execute(SQL(fragment: fragment))
        let built = (trace.inserts, try written(transaction))
        try transaction.execute("DELETE FROM \(raw: table)")
        trace.stop()
        return (planned, built)
      }
      #expect(planned.1 == built.1, sourceLocation: sourceLocation)
      #expect(!planned.1.isEmpty, sourceLocation: sourceLocation)
      #if SystemSQLite
        #expect(planned.0.count == 1, sourceLocation: sourceLocation)
        #expect(planned.0 == built.0, sourceLocation: sourceLocation)
      #endif
    }
  }

  // Records the statements a connection runs, with their values bound, through SQLite's trace
  // hook, which is what lets the oracle see what a run bound. Only the system build has the hook
  // to call directly.
  private final class StatementTrace: @unchecked Sendable {
    var inserts: [String] = []
    let connection: OpaquePointer

    init(_ connection: OpaquePointer) {
      self.connection = connection
      #if SystemSQLite
        sqlite3_trace_v2(
          connection,
          UInt32(SQLITE_TRACE_STMT),
          { _, context, statement, _ in
            let trace = Unmanaged<StatementTrace>.fromOpaque(context!).takeUnretainedValue()
            guard let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
            defer { sqlite3_free(expanded) }
            let sql = String(cString: expanded)
            guard sql.hasPrefix("INSERT") else { return 0 }
            // The query builder lays a statement out over several lines under test.
            trace.inserts.append(
              sql.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
            )
            return 0
          },
          Unmanaged.passUnretained(self).toOpaque()
        )
      #endif
    }

    func stop() {
      #if SystemSQLite
        sqlite3_trace_v2(connection, 0, nil, nil)
      #endif
    }
  }

  // MARK: - Models

  private enum Priority: Int, QueryBindable {
    case low = 1
    case high = 3
  }

  @Table("everything")
  private struct Everything: Equatable {
    let id: Int
    var integer: Int
    var real: Double
    var text: String
    var flag: Bool
    var data: Data
    var optionalText: String?
    var optionalInteger: Int?
    var date: Date
    @Column(as: Date.UnixTimeRepresentation.self) var unixDate: Date
    @Column(as: Date.JulianDayRepresentation.self) var julianDate: Date
    var optionalDate: Date?
    var uuid: UUID
    @Column(as: UUID.BytesRepresentation.self) var uuidBytes: UUID
    @Column(as: UUID.UppercasedRepresentation.self) var uuidUppercased: UUID
    @Column(as: [String].JSONRepresentation.self) var tags: [String]
    var priority: Priority
    var optionalPriority: Priority?
    var unsigned: UInt32
  }

  extension Everything.Draft {
    fileprivate init(_ record: Everything, id: Int?) {
      self.init(record)
      self.id = id
    }
  }

  // Typeless columns store what is bound as it is, so the rows read back show what each path
  // bound rather than what an affinity made of it.
  private let everythingSchema = """
    CREATE TABLE everything (
      id INTEGER PRIMARY KEY, integer, real, text, flag, data, optionalText, optionalInteger,
      date, unixDate, julianDate, optionalDate, uuid, uuidBytes, uuidUppercased, tags, priority,
      optionalPriority, unsigned
    )
    """

  private let everything = [
    Everything(
      id: 1,
      integer: -42,
      real: 3.25,
      text: "Buy \"milk\" 'now'\n",
      flag: true,
      data: Data([0, 1, 2, 255]),
      optionalText: nil,
      optionalInteger: 7,
      date: Date(timeIntervalSince1970: 1_700_000_000.125),
      unixDate: Date(timeIntervalSince1970: 1_700_000_000),
      julianDate: Date(timeIntervalSince1970: 86_400),
      optionalDate: nil,
      uuid: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!,
      uuidBytes: UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!,
      uuidUppercased: UUID(uuidString: "6ba7b812-9dad-11d1-80b4-00c04fd430c8")!,
      tags: ["a", "b \"c\""],
      priority: .high,
      optionalPriority: nil,
      unsigned: .max
    ),
    Everything(
      id: 2,
      integer: 0,
      real: -0.5,
      text: "",
      flag: false,
      data: Data(),
      optionalText: "set",
      optionalInteger: nil,
      date: Date(timeIntervalSince1970: 0),
      unixDate: Date(timeIntervalSince1970: -1),
      julianDate: Date(timeIntervalSince1970: 1_234_567_890.5),
      optionalDate: Date(timeIntervalSince1970: 1),
      uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
      uuidBytes: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
      uuidUppercased: UUID(uuidString: "6BA7B812-9DAD-11D1-80B4-00C04FD430C8")!,
      tags: [],
      priority: .low,
      optionalPriority: .high,
      unsigned: 0
    )
  ]

  @Selection
  private struct Coordinates: Equatable {
    var latitude: Double
    var longitude: Double
  }

  @Table("places")
  private struct Place: Equatable {
    let id: Int
    var name: String
    var coordinates: Coordinates
  }

  @Table("people")
  private struct Person: Equatable {
    let id: Int
    var first: String
    var last: String
    @Column(generated: .stored) let initials: String
  }

  @Table("archived", schema: "archive")
  private struct Archived: Equatable {
    let id: Int
    var name: String
  }

  @Table("reminders")
  private struct Reminder: Equatable {
    let id: Int
    var title: String
    var listID: Int
    var isCompleted = false
    var code: String?
  }

  @Table("children")
  private struct Child: Equatable {
    let id: Int
    var reminderID: Int
  }

  @Table("tags")
  private struct Tag: Equatable {
    let id: Int
    var title: String
  }

  @Table("notes")
  private struct Note: Equatable {
    let id: Int
    var body: String?
  }

  @Table("marks")
  private struct Mark: Equatable {
    let id: Int
    var label: String?
  }
#endif
