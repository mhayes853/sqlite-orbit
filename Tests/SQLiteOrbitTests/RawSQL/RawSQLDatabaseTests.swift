#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  // Like `SQLTests`, this compiles unchanged under every trait, so the call sites below are the
  // raw SQL API as a caller without Structured Queries writes it.
  @Suite
  struct RawSQLDatabaseTests {
    // MARK: - Values and rows

    @Test(
      arguments: [
        OrbitDatabaseValue.null, .integer(0), .integer(.min), .integer(.max), .real(-2.5),
        .real(0.1), .text(""), .text("Blob's 🥛"), .text("a\u{0}b"), .blob([]),
        .blob([0x00, 0xff, 0x10])
      ]
    )
    func valuesRoundTripThroughABoundParameter(_ value: OrbitDatabaseValue) async throws {
      let database = try inMemoryDatabase()
      let read = try await database.read { transaction in
        try transaction.fetchOne("SELECT \(value)") { $0[0] }
      }
      #expect(read == value)
    }

    @Test
    func valuesRoundTripThroughATable() async throws {
      let database = try inMemoryDatabase()
      let values: [OrbitDatabaseValue] = [nil, 1, 2.5, "three", .blob([4])]
      let read = try await database.write { transaction in
        try transaction.executeScript("CREATE TABLE t (id INTEGER PRIMARY KEY, value)")
        for (id, value) in values.enumerated() {
          try transaction.execute("INSERT INTO t (id, value) VALUES (\(id), \(value))")
        }
        return try transaction.fetchAll("SELECT value FROM t ORDER BY id") { $0[0] }
      }
      #expect(read == values)
    }

    @Test
    func rowsReportTheirColumnsByPositionAndName() async throws {
      let database = try inMemoryDatabase()
      let columns = try await database.read { transaction in
        try transaction.fetchOne("SELECT 1 AS id, 'Milk' AS title, NULL AS notes, 2 AS id") {
          row in
          (
            count: row.columnCount,
            names: (0..<row.columnCount).map { row.columnName(at: $0) },
            title: row[column: "title"],
            notes: row[column: "notes"],
            // The first column with a name wins.
            id: row[column: "id"],
            missing: row[column: "missing"],
            // Names are compared exactly.
            differentCase: row[column: "Title"]
          )
        }
      }
      let result = try #require(columns)
      #expect(result.count == 4)
      #expect(result.names == ["id", "title", "notes", "id"])
      #expect(result.title == .text("Milk"))
      #expect(result.notes == .null)
      #expect(result.id == .integer(1))
      #expect(result.missing == nil)
      #expect(result.differentCase == nil)
    }

    @Test
    func aRowCursorLendsEveryRow() async throws {
      let database = try inMemoryDatabase()
      let titles = try await database.read { transaction in
        var cursor = try transaction.rowCursor(
          "SELECT column1 FROM (VALUES ('a'), ('b'), ('c')) ORDER BY 1"
        )
        var titles: [String] = []
        try cursor.forEach { titles.append($0[0].textValue ?? "") }
        return titles
      }
      #expect(titles == ["a", "b", "c"])
    }

    // MARK: - Fetching and executing

    @Test
    func fetchAllAndFetchOneReadEveryRowOrTheFirst() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.executeScript(
          """
          CREATE TABLE reminders (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
          INSERT INTO reminders (title) VALUES ('Milk'), ('Eggs'), ('Bread');
          """
        )
      }
      let (all, first, none) = try await database.read { transaction in
        (
          try transaction.fetchAll("SELECT title FROM reminders ORDER BY id") {
            $0[0].textValue ?? ""
          },
          try transaction.fetchOne("SELECT title FROM reminders ORDER BY id") {
            $0[0].textValue ?? ""
          },
          try transaction.fetchOne("SELECT title FROM reminders WHERE id = \(99)") {
            $0[0].textValue ?? ""
          }
        )
      }
      #expect(all == ["Milk", "Eggs", "Bread"])
      #expect(first == "Milk")
      #expect(none == nil)
    }

    @Test
    func executeBindsItsValuesAndReportsChanges() async throws {
      let database = try inMemoryDatabase()
      let (changes, rowID, stored) = try await database.write { transaction in
        try transaction.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        let body = "'); DROP TABLE notes; --"
        try transaction.execute("INSERT INTO notes (body) VALUES (\(body))")
        return (
          transaction.changesCount,
          transaction.lastInsertedRowID,
          try transaction.fetchOne("SELECT body FROM notes") { $0[0].textValue }
        )
      }
      #expect(changes == 1)
      #expect(rowID == 1)
      #expect(stored == "'); DROP TABLE notes; --")
    }

    @Test
    func writtenSQLBindsItsValuesInOrder() async throws {
      let database = try inMemoryDatabase()
      let rows = try await database.read { transaction in
        try transaction.fetchAll(
          SQL(text: "SELECT ?, ?, ?", bindings: [.integer(1), .text("two"), .null])
        ) { [$0[0], $0[1], $0[2]] }
      }
      #expect(rows == [[.integer(1), .text("two"), .null]])

      let raw = SQL(text: "SELECT '?', ?2, ?1, :name", bindings: [1, "two", "named"])
      let parts = try raw.validatedParts() + [.text(", "), .binding("last")]
      let reordered = try await database.read { transaction in
        try transaction.fetchOne(SQL(parts: parts)) { [$0[0], $0[1], $0[2], $0[3], $0[4]] }
      }
      #expect(reordered == ["?", "two", 1, "named", "last"])

      // A parameter without a value is NULL, and a value without a parameter is refused.
      let unbound = try await database.read { transaction in
        try transaction.fetchOne(SQL(text: "SELECT ?, ?", bindings: [.integer(1)])) { $0[1] }
      }
      #expect(unbound == .null)
      let error = await #expect(throws: SQLiteError.self) {
        try await database.read { transaction in
          try transaction.fetchOne(SQL(text: "SELECT ?", bindings: [.integer(1), .integer(2)])) {
            $0[0]
          }
        }
      }
      #expect(error?.code.rawValue == 25)
    }

    @Test
    func writeTransactionsFetchWhatReturningReports() async throws {
      let database = try inMemoryDatabase()
      let (inserted, deleted, stopped) = try await database.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT)")
        let inserted = try transaction.fetchAll(
          "INSERT INTO items (title) VALUES ('a'), ('b'), ('c') RETURNING id"
        ) { $0[0].integerValue ?? 0 }
        let deleted = try transaction.fetchOne(
          "DELETE FROM items WHERE id = \(2) RETURNING title"
        ) { $0[0].textValue }
        var stopped: [Int64] = []
        try transaction.execute("UPDATE items SET title = upper(title) RETURNING id") { row in
          stopped.append(row[0].integerValue ?? 0)
          return .stop
        }
        return (inserted, deleted, stopped)
      }
      #expect(inserted == [1, 2, 3])
      #expect(deleted == "b")
      #expect(stopped.count == 1)
    }

    @Test
    func anExecuteRowCursorLendsReturnedRows() async throws {
      let database = try inMemoryDatabase()
      let ids = try await database.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        var cursor = try transaction.executeRowCursor(
          "INSERT INTO items (id) VALUES (\(5)), (\(6)) RETURNING id"
        )
        var ids: [Int64] = []
        while let row = try cursor.next() { ids.append(row[0].integerValue ?? 0) }
        return ids
      }
      #expect(ids == [5, 6])
    }

    @Test
    func emptySQLSelectsNothingAndExecutesNothing() async throws {
      let database = try inMemoryDatabase()
      let (rows, changes) = try await database.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try transaction.execute("INSERT INTO items (id) VALUES (1), (2)")
        try transaction.execute("")
        return (try transaction.fetchAll("") { $0.columnCount }, transaction.changesCount)
      }
      #expect(rows.isEmpty)
      #expect(changes == 2)

      // SQL that holds only whitespace or comments holds no statement either.
      for sql: SQL in ["  \n", "-- nothing", "/* nothing */ ;"] {
        let rows = try await database.read { transaction in
          try transaction.fetchAll(sql) { $0.columnCount }
        }
        #expect(rows.isEmpty)
        try await database.write { try $0.execute(sql) }
        try await database.writeWithoutTransaction { try $0.execute(sql) }
      }
    }

    @Test
    func aStatementThatFailsToPrepareThrows() async throws {
      let database = try inMemoryDatabase()
      await #expect(throws: SQLiteError.self) {
        try await database.read { transaction in
          try transaction.fetchAll("SELECT * FROM missing") { $0[0] }
        }
      }
      await #expect(throws: SQLiteError.self) {
        try await database.read { transaction in
          var cursor = try transaction.rowCursor("SELECT * FROM missing")
          _ = try cursor.next()
        }
      }
      await #expect(throws: SQLiteError.self) {
        try await database.write { transaction in
          try transaction.execute("INSERT INTO missing VALUES (1)")
        }
      }
    }

    // MARK: - Scripts

    @Test
    func scriptsRunEveryStatementWhileSQLRefusesMoreThanOne() async throws {
      let database = try inMemoryDatabase()
      let script = """
        CREATE TABLE items (id INTEGER PRIMARY KEY);
        INSERT INTO items (id) VALUES (1);
        -- A trailing comment prepares nothing.
        """
      try await database.write { try $0.executeScript(script) }
      #expect(try await database.rowCount(of: "items") == 1)

      let error = await #expect(throws: SQLiteError.self) {
        try await database.write { transaction in
          try transaction.execute("INSERT INTO items (id) VALUES (2); INSERT INTO items VALUES (3)")
        }
      }
      #expect(error?.primaryCode == .error)
      #expect(try await database.rowCount(of: "items") == 1)

      // Trailing semicolons and comments are not another statement.
      try await database.write { transaction in
        try transaction.execute("INSERT INTO items (id) VALUES (\(4)); -- done")
      }
      #expect(try await database.rowCount(of: "items") == 2)
    }

    @Test
    func aScriptOnAConnectionCommitsEachStatement() async throws {
      let database = try inMemoryDatabase()
      try await database.writeWithoutTransaction { connection in
        try connection.executeScript(
          "CREATE TABLE items (id INTEGER PRIMARY KEY); INSERT INTO items (id) VALUES (1)"
        )
        try connection.execute("INSERT INTO items (id) VALUES (\(2))")
      }
      #expect(try await database.rowCount(of: "items") == 2)
    }

    // MARK: - Read-only enforcement

    @Test(arguments: SQLiteTestDriver.allCases)
    func readTransactionsRefuseSQLThatMayWrite(_ kind: SQLiteTestDriver) async throws {
      try await kind.withDatabase(schema: "CREATE TABLE items (id INTEGER PRIMARY KEY)") {
        database in
        let statements: [SQL] = [
          "INSERT INTO items (id) VALUES (1)",
          "DELETE FROM items",
          "CREATE TABLE other (id INTEGER)",
          // Querying the journal mode can also change it, so SQLite reports it may write.
          "PRAGMA journal_mode"
        ]
        for sql in statements {
          let error = await #expect(throws: SQLiteError.self) {
            try await database.read { transaction in
              try transaction.fetchAll(sql) { $0.columnCount }
            }
          }
          #expect(error?.code == .readOnly)
          #expect(error?.sql == sql.text)

          let connectionError = await #expect(throws: SQLiteError.self) {
            try await database.readWithoutTransaction { connection in
              var cursor = try connection.rowCursor(sql)
              _ = try cursor.next()
            }
          }
          #expect(connectionError?.code == .readOnly)
        }
        #expect(try await database.rowCount(of: "items") == 0)
        #expect(try await database.tableNames() == ["items"])

        // What only reads is accepted, including the table-valued form of the same pragma.
        let mode = try await database.read { transaction in
          try transaction.fetchOne("SELECT * FROM pragma_journal_mode") { $0[0].textValue }
        }
        #expect(mode != nil)
      }
    }

    @Test
    func aWriteTransactionRunsAReadQueryThatWrites() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        // Only a read transaction holds a statement to reading; a write transaction may write.
        var cursor = try transaction.rowCursor(
          OrbitDatabaseQuery<OrbitDatabaseReadAccess>("INSERT INTO items (id) VALUES (1)"),
          cached: false
        )
        _ = try cursor.next()
      }
      #expect(try await database.rowCount(of: "items") == 1)
    }

    @Test
    func regionsAreDerivedFromSQL() async throws {
      let database = try inMemoryDatabase()
      try await database.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT)")
      let region = try await database.read { transaction in
        try OrbitDatabaseRegion("SELECT title FROM items WHERE id = \(1)", in: transaction)
      }
      #expect(region == OrbitDatabaseRegion(columns: ["id", "title"], in: "items"))
    }

    @Test
    func rawSectionFetchingPreservesOrderAndPropagatesErrors() throws {
      let database = try inMemoryDatabase()
      let sql: SQL = "SELECT column1, column2 FROM (VALUES ('A', 2), ('B', NULL), ('C', 2))"
      try database.readBlocking { transaction in
        var calls = 0
        let sections = try transaction.fetchSections(sql) { row in
          calls += 1
          return (row[0].textValue, row[1].integerValue)
        }
        #expect(calls == 3)
        #expect(sections.elements == ["A", "B", "C"])
        #expect(sections.sectionNames == [2, nil])
        #expect(sections[sectionName: 2]?.map { $0 } == ["A", "C"])
        let empty = try transaction.fetchSections(sql + " WHERE 0") { ($0[0], $0[1].integerValue) }
        #expect(empty.isEmpty && empty.elements.isEmpty)
        #expect(throws: SQLiteError.self) {
          _ = try transaction.fetchSections("SELECT * FROM missing_table") { ($0[0], 0) }
        }
        #expect(throws: NativeFunctionFailure.self) {
          _ = try transaction.fetchSections(sql) { _ -> (Int, Int) in throw NativeFunctionFailure()
          }
        }
        // A throwing transform releases its cursor, leaving the cached statement reusable.
        let retried = try transaction.fetchSections(sql) { ($0[0].textValue, $0[1].integerValue) }
        #expect(retried == sections)
      }
    }

    // MARK: - Functions

    @Test
    func nativeScalarFunctionsReceiveAndReturnValues() async throws {
      var configuration = SQLiteConfiguration.default
      configuration.registerFunction("describe", argumentCount: nil, flags: [.deterministic]) {
        arguments in
        var parts: [String] = []
        for index in 0..<arguments.count {
          switch arguments[index] {
          case .null: parts.append("null")
          case .integer(let value): parts.append("integer \(value)")
          case .real(let value): parts.append("real \(value)")
          case .text(let value): parts.append("text \(value)")
          case .blob(let value): parts.append("blob \(value.count)")
          }
        }
        return .text(parts.joined(separator: ", "))
      }
      configuration.registerFunction("echo", argumentCount: 1) { $0[0] }
      configuration.registerFunction("fail", argumentCount: 0) { _ in
        throw NativeFunctionFailure()
      }
      let database = try inMemoryDatabase(configuration: configuration)

      let (described, none, echoed) = try await database.read { transaction in
        (
          try transaction.fetchOne("SELECT describe(NULL, 1, 2.5, 'a', x'0102')") {
            $0[0].textValue
          },
          try transaction.fetchOne("SELECT describe()") { $0[0].textValue },
          try transaction.fetchAll(
            "SELECT echo(column1) FROM (VALUES (NULL), (1), (2.5), ('a'), (x'00'))"
          ) { $0[0] }
        )
      }
      #expect(described == "null, integer 1, real 2.5, text a, blob 2")
      #expect(none == "")
      #expect(echoed == [nil, 1, 2.5, "a", .blob([0])])

      let error = await #expect(throws: SQLiteError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT fail()") { $0[0] }
        }
      }
      #expect(error?.message?.contains("NativeFunctionFailure") == true)
    }

    @Test
    func nativeAggregateFunctionsAccumulateEachGroup() async throws {
      var configuration = SQLiteConfiguration.default
      configuration.registerAggregateFunction("longest", argumentCount: 1, LongestText())
      configuration.registerAggregateFunction("failing", argumentCount: 1, FailingAccumulator())
      let database = try inMemoryDatabase(configuration: configuration)
      try await database.execute(
        sql: """
          CREATE TABLE words (list INTEGER, word TEXT);
          INSERT INTO words VALUES (1, 'a'), (1, 'abc'), (1, 'ab'), (2, 'xy'), (2, NULL);
          """
      )

      let (byGroup, empty) = try await database.read { transaction in
        (
          try transaction.fetchAll("SELECT longest(word) FROM words GROUP BY list ORDER BY list") {
            $0[0].textValue
          },
          // A group with no rows is finished without a step.
          try transaction.fetchOne("SELECT longest(word) FROM words WHERE 0") { $0[0] }
        )
      }
      #expect(byGroup == ["abc", "xy"])
      #expect(empty == .null)

      let error = await #expect(throws: SQLiteError.self) {
        try await database.read { transaction in
          try transaction.fetchOne("SELECT failing(word) FROM words") { $0[0] }
        }
      }
      #expect(error?.message?.contains("NativeFunctionFailure") == true)
    }

    @Test
    func connectionLocalRegistrationsSurviveLendingAndHonorFlags() throws {
      let factories = Lock(0)
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withConnectionAccess { connection in
        try connection.registerFunction(
          "echo",
          argumentCount: 1,
          flags: [.deterministic, .innocuous]
        ) { $0[0] }
        try connection.registerFunction("direct", argumentCount: 0, flags: [.directOnly]) { _ in 1 }
        try connection.registerAggregateFunction(
          "longest",
          argumentCount: 1,
          {
            factories.withLock { $0 += 1 }
            return LongestText()
          }()
        )
        try connection.registerCollation("length") { lhs, rhs in
          lhs.count < rhs.count ? .ascending : lhs.count > rhs.count ? .descending : .same
        }
        try connection.executeScript(
          """
          CREATE TABLE words (list INTEGER, word TEXT);
          INSERT INTO words VALUES (1, 'abc'), (1, 'a'), (2, 'xy');
          CREATE INDEX echo_index ON words(echo(word));
          CREATE VIEW forbidden AS SELECT direct();
          """
        )
      }
      #expect(factories.withLock { $0 } == 0)
      try owner.withReadConnection { (connection: borrowing SQLiteReadConnection) throws in
        #expect(
          try connection.fetchAll(
            "SELECT echo(word) FROM words ORDER BY word COLLATE length"
          ) { $0[0].textValue } == ["a", "xy", "abc"]
        )
        #expect(
          try connection.fetchAll(
            "SELECT longest(word) FROM words GROUP BY list ORDER BY list"
          ) { $0[0].textValue } == ["abc", "xy"]
        )
        #expect(
          try connection.fetchOne("SELECT longest(word) FROM words WHERE 0") { $0[0] } == .null
        )
        #expect(try connection.fetchOne("SELECT direct()") { $0[0] } == 1)
        #expect(throws: SQLiteError.self) {
          _ = try connection.fetchOne("SELECT * FROM forbidden") { $0[0] }
        }
      }
      #expect(factories.withLock { $0 } == 3)
      // Replacing a function also updates a statement cached under its previous definition.
      try owner.withConnectionAccess { connection in
        try connection.registerFunction("direct", argumentCount: 0) { _ in 2 }
      }
      let replaced = try owner.withReadConnection { connection in
        try connection.fetchOne("SELECT direct()") { $0[0] }
      }
      #expect(replaced == 2)
    }

    @Test
    func connectionLocalRegistrationReportsMissingCapabilities() throws {
      var configuration = SQLiteConfiguration.default
      configuration.library.scalarFunctions = nil
      configuration.library.aggregateFunctions = nil
      configuration.library.collations = nil
      var owner = try SQLiteConnection(path: ":memory:", configuration: configuration)
      try owner.withConnectionAccess { connection in
        #expect(
          throws: SQLiteFeatureUnavailableError(
            libraryName: configuration.library.name,
            feature: .scalarFunctions
          )
        ) { try connection.registerFunction("echo", argumentCount: 1) { $0[0] } }
        #expect(
          throws: SQLiteFeatureUnavailableError(
            libraryName: configuration.library.name,
            feature: .aggregateFunctions
          )
        ) { try connection.registerAggregateFunction("longest", argumentCount: 1, LongestText()) }
        #expect(
          throws: SQLiteFeatureUnavailableError(
            libraryName: configuration.library.name,
            feature: .collations
          )
        ) { try connection.registerCollation("same") { _, _ in .same } }
      }
    }

    @Test
    func invalidFunctionRegistrationsThrowInsteadOfTrappingOrTruncating() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withConnectionAccess { connection in
        for count in [Int.min, -1, Int.max] {
          #expect(throws: SQLiteError.self) {
            try connection.registerFunction("invalid", argumentCount: count) { _ in nil }
          }
          #expect(throws: SQLiteError.self) {
            try connection.registerAggregateFunction("invalid", argumentCount: count, LongestText())
          }
        }
        for name in ["invalid\u{0}suffix", String(repeating: "x", count: 256)] {
          #expect(throws: SQLiteError.self) {
            try connection.registerFunction(name, argumentCount: 0) { _ in nil }
          }
        }
        #expect(throws: SQLiteError.self) {
          try connection.registerCollation("invalid\u{0}suffix") { _, _ in .same }
        }
      }
    }

    // MARK: - Collations

    @Test
    func nativeCollationsOrderByTheirComparator() async throws {
      var configuration = SQLiteConfiguration.default
      configuration.registerCollation("length") { lhs, rhs in
        lhs.count < rhs.count ? .ascending : lhs.count > rhs.count ? .descending : .same
      }
      let database = try inMemoryDatabase(configuration: configuration)
      try await database.execute(
        sql: """
          CREATE TABLE words (word TEXT);
          INSERT INTO words VALUES ('abc'), ('a'), ('🥛'), ('ab');
          """
      )

      let (ordered, equalLengths) = try await database.read { transaction in
        (
          // The comparator sees UTF-8 bytes, so the four-byte emoji sorts last.
          try transaction.fetchAll("SELECT word FROM words ORDER BY word COLLATE length") {
            $0[0].textValue
          },
          try transaction.fetchOne("SELECT 'xy' = 'ab' COLLATE length") { $0[0] }
        )
      }
      #expect(ordered == ["a", "ab", "abc", "🥛"])
      #expect(equalLengths == 1)
    }
  }

  private struct NativeFunctionFailure: Error {}

  private struct LongestText: SQLiteAggregateAccumulator {
    var longest: String?

    mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
      guard let text = arguments[0].textValue else { return }
      if text.count > longest?.count ?? -1 { longest = text }
    }

    func finish() throws -> OrbitDatabaseValue {
      longest.map(OrbitDatabaseValue.text) ?? nil
    }
  }

  private struct FailingAccumulator: SQLiteAggregateAccumulator {
    mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
      throw NativeFunctionFailure()
    }

    func finish() throws -> OrbitDatabaseValue {
      throw NativeFunctionFailure()
    }
  }
#endif
