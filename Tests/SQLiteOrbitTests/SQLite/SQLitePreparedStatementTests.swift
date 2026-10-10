#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  // A prepared statement compiles once and runs again and again with new values, so these run
  // each statement several times, around everything that could leave a run with stale state:
  // cursors dropped early, failed runs, schema changes, authorization scopes and other
  // transactions.
  @Suite
  struct SQLitePreparedStatementTests {
    @Test(arguments: [true, false])
    func executeRunsTheStatementOncePerArgumentList(cached: Bool) throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.write { transaction in
        try transaction.execute("CREATE TABLE items (a INTEGER, b TEXT, c REAL)")
        var insert = try transaction.prepare(
          "INSERT INTO items (a, b, c) VALUES (?, ?, ?)",
          cached: cached
        )
        #expect(insert.parameterCount == 3)
        #expect(insert.sql == "INSERT INTO items (a, b, c) VALUES (?, ?, ?)")
        for i in 0..<5 {
          try insert.execute(i, "row \(i)", Double(i) / 2)
          #expect(transaction.changesCount == 1)
          #expect(transaction.lastInsertedRowID == Int64(i + 1))
        }
        // A `nil` argument binds `NULL` rather than leaving the last run's value in place.
        try insert.execute(5, String?.none, 2.5)
      }
      let rows = try owner.read { transaction in
        try transaction.fetchAll("SELECT a, b, c FROM items ORDER BY a") {
          "\($0[0].integerValue ?? -1) \($0[1].textValue ?? "nil") \($0[2].realValue ?? -1)"
        }
      }
      #expect(rows == (0..<5).map { "\($0) row \($0) \(Double($0) / 2)" } + ["5 nil 2.5"])
    }

    @Test
    func fetchesRunWithEachRunsArguments() throws {
      var owner = try itemsConnection()
      try owner.read { transaction in
        var byGroup = try transaction.prepare("SELECT a FROM items WHERE grp = ? ORDER BY a")
        var count = try transaction.prepare("SELECT count(*) FROM items WHERE grp = :group")
        var item = try transaction.prepare("SELECT a, label FROM items WHERE a = $a")
        for _ in 0..<2 {
          #expect(try byGroup.fetchAll("x", as: Int.self) == [1, 3])
          #expect(try byGroup.fetchAll("y", as: Int.self) == [2])
          #expect(try byGroup.fetchAll("z", as: Int.self) == [])
          #expect(try byGroup.fetchAll("x") { $0[0].integerValue } == [1, 3])
          #expect(try byGroup.fetchOne("x", as: Int.self) == 1)
          #expect(try byGroup.fetchOne("z", as: Int.self) == nil)
          #expect(try byGroup.fetchOne("y") { $0[0].integerValue } == 2)
          #expect(try count.fetchOne("x", as: Int.self) == 2)
          #expect(try count.fetchOne("y", as: Int.self) == 1)
          #expect(try item.fetchOne(3, as: Item.self) == Item(a: 3, label: "three"))
          #expect(try item.fetchAll(2, as: Item.self) == [Item(a: 2, label: "two")])
          // A type convertible both ways is read as a row, as the transaction reads it.
          #expect(try item.fetchOne(1, as: Both.self)?.source == "row")
          #expect(try item.fetchAll(1, as: Both.self).map(\.source) == ["row"])
        }
      }
    }

    @Test
    func cursorsLendEachRunsRows() throws {
      var owner = try itemsConnection()
      try owner.read { transaction in
        var byGroup = try transaction.prepare("SELECT a, label FROM items WHERE grp = ? ORDER BY a")
        for (group, expected) in [("x", [1, 3]), ("y", [2]), ("x", [1, 3])] {
          var values: [Int] = []
          var cursor = try byGroup.rowCursor(group)
          while let row = try cursor.next() {
            values.append(row[0].integerValue.map(Int.init) ?? -1)
          }
          #expect(values == expected)
        }
        for (group, expected) in [("y", ["two"]), ("x", ["one", "three"])] {
          var items = try byGroup.fetchCursor(group, as: Item.self)
          var labels: [String] = []
          while let item = try items.next() { labels.append(item.label) }
          #expect(labels == expected)
        }
      }
    }

    @Test
    func valuesGatheredAtRuntimeBindByPosition() throws {
      var owner = try itemsConnection()
      try owner.write { transaction in
        var insert = try transaction.prepare("INSERT INTO items (a, grp, label) VALUES (?, ?, ?)")
        try insert.execute(bindings: [.integer(4), .text("y"), .text("four")])
        try insert.execute(bindings: [.integer(5), .text("y"), .null])

        var byGroup = try transaction.prepare("SELECT a, label FROM items WHERE grp = ? ORDER BY a")
        #expect(try byGroup.fetchAll(bindings: [.text("y")], as: Int.self) == [2, 4, 5])
        #expect(
          try byGroup.fetchAll(bindings: [.text("y")]) { $0[1].textValue } == ["two", "four", nil]
        )
        #expect(try byGroup.fetchOne(bindings: [.text("x")], as: Int.self) == 1)
        #expect(try byGroup.fetchOne(bindings: [.text("x")]) { $0[1].textValue } == "one")
        #expect(
          try byGroup.fetchOne(bindings: [.text("y")], as: Item.self) == Item(a: 2, label: "two")
        )
        #expect(try byGroup.fetchAll(bindings: [.text("x")], as: Item.self).map(\.a) == [1, 3])
        #expect(
          try byGroup.fetchAll(bindings: [.text("x")], as: Both.self).map(\.source) == [
            "row", "row"
          ]
        )
        var cursor = try byGroup.rowCursor(bindings: [.text("x")])
        #expect(try cursor.next()?[0].integerValue == 1)
        var items = try byGroup.fetchCursor(bindings: [.text("y")], as: Item.self)
        #expect(try items.next()?.label == "two")
      }
    }

    @Test
    func aRunWithTheWrongNumberOfArgumentsIsRefusedBeforeRunning() throws {
      var owner = try itemsConnection()
      try owner.write { transaction in
        var insert = try transaction.prepare("INSERT INTO items (a, grp) VALUES (?, ?)")
        // Runs once first, so a missing argument would otherwise reuse this run's value.
        try insert.execute(10, "q")
        let tooFew = #expect(throws: SQLiteError.self) { try insert.execute(11) }
        #expect(tooFew?.primaryCode == .range)
        #expect(tooFew?.sql == "INSERT INTO items (a, grp) VALUES (?, ?)")
        let tooMany = #expect(throws: SQLiteError.self) { try insert.execute(11, "q", 0) }
        #expect(tooMany?.primaryCode == .range)
        let none = #expect(throws: SQLiteError.self) { try insert.execute() }
        #expect(none?.primaryCode == .range)
        let runtime = #expect(throws: SQLiteError.self) {
          try insert.execute(bindings: [.integer(11)])
        }
        #expect(runtime?.primaryCode == .range)

        var byGroup = try transaction.prepare("SELECT a FROM items WHERE grp = ?")
        #expect(throws: SQLiteError.self) { try byGroup.fetchAll(as: Int.self) }
        #expect(throws: SQLiteError.self) { try byGroup.fetchOne("q", 1, as: Int.self) }
        #expect(throws: SQLiteError.self) { _ = try byGroup.rowCursor(bindings: []) }

        // Nothing ran, and the statements still run.
        try insert.execute(11, "q")
        #expect(try byGroup.fetchAll("q", as: Int.self) == [10, 11])
      }
    }

    @Test
    func numberedParametersAreCountedAsSQLiteCountsThem() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.read { transaction in
        var repeated = try transaction.prepare("SELECT ?1 + ?1, ?2")
        #expect(repeated.parameterCount == 2)
        #expect(try repeated.fetchOne(2, "b") { $0[0].integerValue } == 4)
        var gap = try transaction.prepare("SELECT ?3")
        #expect(gap.parameterCount == 3)
        #expect(try gap.fetchOne(1, 2, 3, as: Int.self) == 3)
      }
    }

    @Test
    func interpolatedValuesAreRefused() throws {
      var owner = try itemsConnection()
      try owner.write { transaction in
        let interpolated = #expect(throws: SQLiteError.self) {
          _ = try transaction.prepare("SELECT a FROM items WHERE a = \(1)")
        }
        #expect(interpolated?.primaryCode == .misuse)
        let prebound = #expect(throws: SQLiteError.self) {
          _ = try transaction.prepare(SQL(text: "SELECT ?", bindings: [.integer(1)]))
        }
        #expect(prebound?.primaryCode == .misuse)
        // A value that failed to convert is reported as itself.
        #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
          _ = try transaction.prepare("SELECT \(UInt64.max)")
        }
        #expect(transaction.base.statements.idleStatementCount == 0)

        // Spliced text carries no values, so it is welcome.
        let table = "items"
        var spliced = try transaction.prepare(
          "SELECT \(quote: "a") FROM \(raw: table) WHERE grp = ?" + SQL(text: " ORDER BY a")
        )
        #expect(try spliced.fetchAll("x", as: Int.self) == [1, 3])
      }
    }

    @Test
    func aReadTransactionRefusesAStatementThatMayWrite() throws {
      var owner = try itemsConnection()
      for cached in [true, false] {
        try owner.read { transaction in
          let error = #expect(throws: SQLiteError.self) {
            _ = try transaction.prepare("DELETE FROM items WHERE a = ?", cached: cached)
          }
          #expect(error?.primaryCode == .readOnly)
        }
      }
      // A write transaction compiles it, and the read transaction above gave it back.
      try owner.write { transaction in
        var delete = try transaction.prepare("DELETE FROM items WHERE a = ?")
        try delete.execute(1)
        #expect(transaction.changesCount == 1)
      }
    }

    @Test
    func sqlHoldingNoStatementRunsNothing() throws {
      var owner = try itemsConnection()
      try owner.write { transaction in
        for sql: SQL in ["", "  ", "-- nothing"] {
          var nothing = try transaction.prepare(sql)
          #expect(nothing.parameterCount == 0)
          try nothing.execute()
          #expect(try nothing.fetchAll(as: Int.self) == [])
          #expect(try nothing.fetchOne { $0[0].integerValue } == nil)
          var cursor = try nothing.rowCursor()
          #expect(try cursor.next() == nil)
          var items = try nothing.fetchCursor(as: Item.self)
          #expect(try items.next() == nil)
          let error = #expect(throws: SQLiteError.self) { try nothing.execute(1) }
          #expect(error?.primaryCode == .range)
        }
      }
    }

    @Test
    func aCursorDroppedPartwayLeavesTheStatementReadyToRunAgain() throws {
      var owner = try itemsConnection()
      try owner.read { transaction in
        var all = try transaction.prepare("SELECT a FROM items WHERE a >= ? ORDER BY a")
        do {
          var cursor = try all.rowCursor(1)
          #expect(try cursor.next()?[0].integerValue == 1)
        }
        #expect(try all.fetchAll(2, as: Int.self) == [2, 3])
        do {
          var items = try all.fetchCursor(1, as: Single.self)
          _ = try items.next()
        }
        // A cursor whose last use has passed no longer holds the statement, though Swift only
        // destroys it at the end of its scope, after the runs below have begun.
        var early = try all.rowCursor(1)
        #expect(try early.next()?[0].integerValue == 1)
        var later = try all.rowCursor(2)
        #expect(try later.next()?[0].integerValue == 2)
        #expect(try all.fetchAll(3, as: Int.self) == [3])
        #expect(try all.fetchOne(3, as: Int.self) == 3)
        #expect(try all.fetchAll(1, as: Int.self) == [1, 2, 3])
      }
    }

    @Test
    func aFailedRunThrowsCleanlyAndLeavesTheStatementUsable() throws {
      var owner = try itemsConnection()
      try owner.write { transaction in
        var insert = try transaction.prepare("INSERT INTO items (a, grp) VALUES (?, ?)")
        #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
          try insert.execute(UInt64.max, "q")
        }
        var byGroup = try transaction.prepare("SELECT a FROM items WHERE grp = ? AND a < ?")
        #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
          var cursor = try byGroup.rowCursor("x", UInt64.max)
          _ = try cursor.next()
        }
        #expect(throws: SQLiteError.self) {
          var cursor = try byGroup.rowCursor("x")
          _ = try cursor.next()
        }
        #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
          var items = try byGroup.fetchCursor("x", UInt64.max, as: Item.self)
          _ = try items.next()
        }
        #expect(throws: SQLiteError.self) {
          var compiled = try transaction.prepare("SELECT FROM nowhere WHERE")
          _ = try compiled.fetchAll(as: Int.self)
        }
        // A constraint failure partway through a run is reported, and the next run starts clean.
        try transaction.execute("CREATE UNIQUE INDEX items_a ON items (a)")
        var unique = try transaction.prepare("INSERT INTO items (a, grp) VALUES (?, ?)")
        let duplicate = #expect(throws: SQLiteError.self) { try unique.execute(1, "q") }
        #expect(duplicate?.primaryCode == .constraint)
        try unique.execute(UInt64(20), "q")
        #expect(try byGroup.fetchAll("q", 100, as: Int.self) == [20])
      }
    }

    @Test
    func aStatementDroppedInOneTransactionIsReusedByTheNext() throws {
      var owner = try itemsConnection()
      let sql: SQL = "SELECT a FROM items WHERE grp = ?"
      let pointer = try owner.read { transaction in
        let statements = transaction.statements
        let idle = statements.idleStatementCount
        let statement = try transaction.prepare(sql)
        // Checked out, so nothing else can be lent it while it is held.
        #expect(statements.idleStatementCount == idle)
        return statement.state!.statement.pointer
      }
      try owner.read { transaction in
        var statement = try transaction.prepare(sql)
        #expect(statement.state?.statement.pointer == pointer)
        #expect(try statement.fetchAll("y", as: Int.self) == [2])
      }
      try owner.write { transaction in
        var statement = try transaction.prepare(sql)
        #expect(statement.state?.statement.pointer == pointer)
        #expect(try statement.fetchAll("x", as: Int.self) == [1, 3])
      }
    }

    @Test(.libraryHooks)
    func anUncachedStatementIsFinalizedWhenDropped() throws {
      let finalized = Lock<[UInt]>([])
      var configuration = SQLiteConfiguration.default
      configuration.library.statements.execution.finalize = LibraryHooks.finalize { statement in
        if let statement { finalized.withLock { $0.append(UInt(bitPattern: statement)) } }
        return builtInTestLibrary.statements.execution.finalize(statement)
      }
      var owner = try SQLiteConnection(path: ":memory:", configuration: configuration)
      try owner.write { transaction in
        try transaction.execute("CREATE TABLE items (a INTEGER)")
        let pointer = try {
          var insert = try transaction.prepare("INSERT INTO items VALUES (?)", cached: false)
          try insert.execute(1)
          try insert.execute(2)
          #expect(
            !finalized.withLock { $0.contains(UInt(bitPattern: insert.state!.statement.pointer)) }
          )
          return UInt(bitPattern: insert.state!.statement.pointer)
        }()
        #expect(finalized.withLock { $0.contains(pointer) })
        #expect(transaction.base.statements.idleStatementCount == 0)
        #expect(try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self) == 2)
      }
    }

    @Test
    func runsReportWhatTheyReadAndChange() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute("CREATE TABLE items (a INTEGER, b TEXT)")
        try transaction.execute("CREATE TABLE other (a INTEGER)")
      }
      let recorder = TransactionEventRecorder()
      let subscription = try database.subscribe(transactionObserver: recorder)
      defer { subscription.cancel() }
      try await database.write { transaction in
        var insert = try transaction.prepare("INSERT INTO items (a, b) VALUES (?, ?)")
        try insert.execute(1, "one")
        try insert.execute(2, "two")
      }
      #expect(
        recorder.changedRegions == [
          OrbitDatabaseRegion(table: "items"), OrbitDatabaseRegion(table: "items")
        ]
      )
      #expect(recorder.commits.count == 1)

      // Each run reports what the same query run through the transaction reports.
      recorder.removeAll()
      let titles = try await database.read { transaction in
        try transaction.withObservation(recorder) {
          var select = try transaction.prepare("SELECT b FROM items WHERE a = ?")
          return [try select.fetchOne(1, as: String.self), try select.fetchOne(2, as: String.self)]
        }
      }
      #expect(titles == ["one", "two"])
      let preparedReads = recorder.readRegions
      recorder.removeAll()
      try await database.read { transaction in
        try transaction.withObservation(recorder) {
          for a in 1...2 {
            _ = try transaction.fetchOne("SELECT b FROM items WHERE a = \(a)", as: String.self)
          }
        }
      }
      #expect(preparedReads == recorder.readRegions)
      #expect(preparedReads.contains(OrbitDatabaseRegion(columns: ["a", "b"], in: "items")))
      #expect(preparedReads.allSatisfy { !$0.overlaps(OrbitDatabaseRegion(table: "other")) })
    }

    @Test
    func aValueObservationSeesWritesMadeByAPreparedStatement() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute("CREATE TABLE items (a INTEGER)")
      }
      let observation = OrbitValueObservation<Int>
        .tracking { transaction in
          try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self) ?? 0
        }
      let values = TestRecorder<Int>()
      let subscription = try observation.subscribe(
        to: database,
        onError: { _ in },
        onChange: { values.append($0.value) }
      )
      defer { subscription.cancel() }
      try await values.waitForCount(1)
      try await database.write { transaction in
        var insert = try transaction.prepare("INSERT INTO items VALUES (?)")
        for i in 0..<3 { try insert.execute(i) }
      }
      try await waitUntil(timeout: .seconds(5)) { values.last == 3 }
      #expect(values.values == [0, 3])
    }

    @Test
    func aSchemaChangeEarlierInTheTransactionIsFollowed() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.write { transaction in
        try transaction.execute("CREATE TABLE t (a INTEGER)")
        var insert = try transaction.prepare("INSERT INTO t (a) VALUES (?)")
        var all = try transaction.prepare("SELECT * FROM t ORDER BY a")
        try insert.execute(1)
        #expect(try all.fetchOne { $0.columnCount } == 1)

        let recorder = TransactionEventRecorder()
        try transaction.withObservation(recorder) {
          try transaction.execute("ALTER TABLE t ADD COLUMN b INTEGER DEFAULT 7")
          try insert.execute(2)
          #expect(try all.fetchAll { [$0[0].integerValue, $0[1].integerValue] } == [[1, 7], [2, 7]])
        }
        // The read is reported with the column the statement reads now.
        #expect(
          recorder.readRegions.last?.contains(OrbitDatabaseRegion(column: "b", in: "t")) == true
        )
        #expect(all.state?.statement.cacheGeneration == transaction.base.statements.generation)

        // A view the statement reads, redefined: the regions follow the new definition.
        try transaction.execute("CREATE TABLE u (x INTEGER)")
        try transaction.execute("INSERT INTO u VALUES (9)")
        try transaction.execute("CREATE VIEW v AS SELECT a AS x FROM t")
        var view = try transaction.prepare("SELECT x FROM v WHERE x > ?")
        #expect(try view.fetchAll(0, as: Int.self) == [1, 2])
        try transaction.execute("DROP VIEW v")
        try transaction.execute("CREATE VIEW v AS SELECT x FROM u")
        recorder.removeAll()
        let values = try transaction.withObservation(recorder) {
          try view.fetchAll(0, as: Int.self)
        }
        #expect(values == [9])
        #expect(recorder.readRegions.last?.overlaps(OrbitDatabaseRegion(table: "u")) == true)
        #expect(recorder.readRegions.last?.overlaps(OrbitDatabaseRegion(table: "t")) == false)
      }
    }

    @Test
    func aRolledBackTransactionKeepsNoneOfItsRuns() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.write { try $0.execute("CREATE TABLE items (a INTEGER)") }
      #expect(throws: TestError.self) {
        try owner.write { transaction in
          var insert = try transaction.prepare("INSERT INTO items VALUES (?)")
          for i in 0..<3 { try insert.execute(i) }
          throw TestError()
        }
      }
      #expect(try owner.read { try $0.fetchOne("SELECT count(*) FROM items", as: Int.self) } == 0)
    }

    @Test
    func aWriteCanCollectItsReturnedRows() throws {
      var owner = try itemsConnection()
      try owner.write { transaction in
        var insert = try transaction.prepare(
          "INSERT INTO items (a, grp, label) VALUES (?, ?, ?) RETURNING a, label"
        )
        #expect(try insert.fetchOne(7, "z", "seven", as: Item.self) == Item(a: 7, label: "seven"))
        #expect(try insert.fetchAll(8, "z", "eight") { $0[1].textValue } == ["eight"])
        // The same SQL run through the transaction while the statement is held gets its own.
        try transaction.execute(
          "INSERT INTO items (a, grp, label) VALUES (?, ?, ?) RETURNING a, label",
          cached: true
        ) { _ in .next }
      }
    }

    #if !Turso
      @Test
      func aStatementCannotRunAcrossAnAuthorizationScopeBoundary() throws {
        var owner = try itemsConnection()
        try owner.read { transaction in
          var outside = try transaction.prepare("SELECT a FROM items WHERE grp = ?")
          #expect(try outside.fetchAll("x", as: Int.self) == [1, 3])
          try transaction.withAuthorization({ _ in .allow }) {
            let inside = #expect(throws: SQLiteError.self) {
              try outside.fetchAll("x", as: Int.self)
            }
            #expect(inside?.primaryCode == .misuse)

            var scoped = try transaction.prepare("SELECT a FROM items WHERE grp = ?")
            #expect(try scoped.fetchAll("y", as: Int.self) == [2])
          }
          let after = #expect(throws: SQLiteError.self) { try outside.fetchAll("x", as: Int.self) }
          #expect(after?.primaryCode == .misuse)
          var again = try transaction.prepare("SELECT a FROM items WHERE grp = ?")
          #expect(try again.fetchAll("x", as: Int.self) == [1, 3])
        }
      }

      @Test
      func aScopeThatDeniesAReadRefusesToPrepareIt() throws {
        var owner = try itemsConnection()
        try owner.read { transaction in
          let denied = #expect(throws: SQLiteError.self) {
            try transaction.withAuthorization({ event in
              if case .read(table: "items", column: _) = event.action { return .deny }
              return .allow
            }) {
              _ = try transaction.prepare("SELECT a FROM items WHERE grp = ?")
            }
          }
          #expect(denied?.primaryCode == .auth)
        }
      }
    #endif

    private func itemsConnection() throws -> SQLiteConnection {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.write { transaction in
        try transaction.executeScript(
          """
          CREATE TABLE items (a INTEGER, grp TEXT, label TEXT);
          INSERT INTO items VALUES (1, 'x', 'one'), (2, 'y', 'two'), (3, 'x', 'three');
          """
        )
      }
      return owner
    }
  }

  private struct Item: ConvertibleFromOrbitDatabaseRow, Equatable {
    let a: Int
    let label: String

    init(a: Int, label: String) {
      self.a = a
      self.label = label
    }

    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(orbitDatabaseRow row: borrowing Row) throws
    {
      a = try row[0, as: Int.self]
      label = try row[1, as: String.self]
    }
  }

  private struct Single: ConvertibleFromOrbitDatabaseRow {
    let a: Int

    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(orbitDatabaseRow row: borrowing Row) throws
    {
      a = try row[0, as: Int.self]
    }
  }

  // Says which conversion made it.
  private struct Both: ConvertibleFromOrbitDatabaseRow, ConvertibleFromOrbitDatabaseValue {
    let source: String

    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(orbitDatabaseRow row: borrowing Row) {
      source = "row"
    }

    init(orbitDatabaseValue value: OrbitDatabaseValue) {
      source = "value"
    }
  }
#endif
