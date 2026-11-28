#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  // `execute` reuses prepared statements by default, so these run the same SQL again and again,
  // cached and not, around statements that change the schema or the connection.
  @Suite
  struct SQLiteCachedExecuteTests {
    @Test(arguments: [true, false])
    func repeatedExecutesRebindEveryRun(cached: Bool) throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.executeScript("CREATE TABLE t (a INTEGER, b TEXT)")
        try connection.transaction { transaction in
          for i in 0..<5 {
            try transaction.execute("INSERT INTO t VALUES (\(i), \("row \(i)"))", cached: cached)
            #expect(transaction.changesCount == 1)
            #expect(transaction.lastInsertedRowID == Int64(i + 1))
          }
          #expect(transaction.base.statements.idleStatementCount == (cached ? 1 : 0))
        }
        let rows = try connection.fetchAll("SELECT a, b FROM t ORDER BY a") {
          "\($0[0].integerValue ?? -1) \($0[1].textValue ?? "")"
        }
        #expect(rows == (0..<5).map { "\($0) row \($0)" })
      }
    }

    @Test
    func cacheKeysCompareTheJoinedTextByteForByte() {
      let text = SQLiteStatementCacheKey("SELECT ?, 'a'")
      let parts = SQLiteStatementCacheKey(
        SQL(parts: [.text("SELECT "), .binding(.integer(1)), .text(", "), .text("'a'")])
      )
      #expect(text == parts)
      #expect(parts == text)
      #expect(text.hashValue == parts.hashValue)
      #expect(SQLiteStatementCacheKey("SELECT ?, 'b'") != parts)
      #expect(SQLiteStatementCacheKey("SELECT ?, 'a' ") != parts)
      #expect(SQLiteStatementCacheKey("SELECT ?") != parts)
      // Canonically equivalent strings are equal in Swift, but SQLite compiles their bytes.
      #expect(
        SQLiteStatementCacheKey("SELECT '\u{E9}'") != SQLiteStatementCacheKey("SELECT 'e\u{301}'")
      )
    }

    @Test
    func aFiledKeyMatchesQueriesByTheirText() {
      func query(_ value: Int, _ table: String) -> SQL {
        "SELECT * FROM \(raw: table) WHERE a = \(value)"
      }
      let filed = SQLiteStatementCacheKey(
        filing: query(0, "t"),
        joinedInto: "SELECT * FROM t WHERE a = ?",
        lookedUpBy: SQLiteStatementCacheKey(query(0, "t"))
      )
      #expect(filed == SQLiteStatementCacheKey("SELECT * FROM t WHERE a = ?"))
      #expect(filed.hashValue == SQLiteStatementCacheKey("SELECT * FROM t WHERE a = ?").hashValue)
      // Built from the same strings, or from different strings holding the same text.
      #expect(filed.matches(query(1, "t")))
      #expect(filed.matches(query(1, String("tx".prefix(1)))))
      #expect(filed.matches(SQL(text: "SELECT * FROM t WHERE a = ?", bindings: [.integer(1)])))
      #expect(!filed.matches(query(1, "u")))
      #expect(!filed.matches("SELECT * FROM t WHERE a = ? "))
    }

    @Test
    func executeOutsideATransactionReusesItsStatement() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.executeScript("CREATE TABLE t (a INTEGER)")
        for i in 0..<3 {
          try connection.execute("INSERT INTO t VALUES (\(i))")
        }
        try connection.execute("INSERT INTO t VALUES (\(3))", cached: false)
        #expect(try connection.fetchOne("SELECT count(*) FROM t", as: Int.self) == 4)
        // A cached statement is still held to the rule that only `transaction` may begin one.
        for _ in 0..<2 {
          #expect(throws: SQLiteError.self) { try connection.execute("BEGIN") }
        }
      }
    }

    @Test
    func cachedStatementsFollowSchemaChangesAndPragmasMadeThroughExecute() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        for version in [3, 4, 3] {
          try connection.execute("PRAGMA user_version = \(raw: String(version))")
          #expect(try connection.fetchOne("PRAGMA user_version", as: Int.self) == version)
        }
        try connection.transaction { transaction in
          for _ in 0..<2 {
            try transaction.execute("CREATE TABLE IF NOT EXISTS t (a INTEGER)")
          }
          try transaction.execute("INSERT INTO t (a) VALUES (\(1))")
          let generation = transaction.base.statements.generation

          // Each schema change empties the cache, the DDL's own statement included.
          try transaction.execute("ALTER TABLE t ADD COLUMN b INTEGER DEFAULT 7")
          #expect(transaction.base.statements.generation != generation)
          #expect(transaction.base.statements.idleStatementCount == 0)

          try transaction.execute("INSERT INTO t (a) VALUES (\(1))")
          #expect(try transaction.fetchAll("SELECT b FROM t", as: Int.self) == [7, 7])

          // The same text against a table dropped and recreated with other columns: a statement
          // compiled against the old table would store an integer.
          try transaction.execute("DROP TABLE t")
          try transaction.execute("CREATE TABLE t (a TEXT)")
          try transaction.execute("INSERT INTO t (a) VALUES (\(1))")
          #expect(try transaction.fetchAll("SELECT typeof(a) FROM t", as: String.self) == ["text"])
          // A view redefined under the same name: SQLiteStatementCacheTests.
        }
      }
    }

    @Test
    func aFailedBindingOrStepGivesTheCachedStatementBack() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.executeScript(
          "CREATE TABLE t (a INTEGER); CREATE TABLE u (a INTEGER PRIMARY KEY)"
        )
        try connection.transaction { transaction in
          try transaction.execute("INSERT INTO t VALUES (\(UInt64(1)))")
          #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
            try transaction.execute("INSERT INTO t VALUES (\(UInt64.max))")
          }
          try transaction.execute("INSERT INTO t VALUES (\(UInt64(2)))")
          #expect(transaction.base.statements.idleStatementCount == 1)

          try transaction.execute("INSERT INTO u VALUES (\(1))")
          #expect(throws: SQLiteError.self) {
            try transaction.execute("INSERT INTO u VALUES (\(1))")
          }
          try transaction.execute("INSERT INTO u VALUES (\(2))")
        }
        #expect(try connection.fetchAll("SELECT a FROM t ORDER BY a", as: Int.self) == [1, 2])
        #expect(try connection.fetchAll("SELECT a FROM u ORDER BY a", as: Int.self) == [1, 2])
      }
    }

    // Cursors reuse statements by default too, holding theirs until they are dropped.

    @Test
    func twoCursorsOverTheSameSQLStepIndependently() throws {
      try withNumbers { connection in
        try connection.transaction { transaction in
          // Leave a statement for this SQL in the cache, so the first cursor is lent it.
          #expect(try transaction.fetchAll(numbers, as: Int.self) == [1, 2, 3])
          #expect(transaction.base.statements.idleStatementCount == 1)

          var first = try transaction.rowCursor(numbers)
          #expect(try first.next()?[0].integerValue == 1)
          #expect(transaction.base.statements.idleStatementCount == 0)

          var second = try transaction.rowCursor(numbers)
          #expect(try second.collect { $0[0].integerValue } == [1, 2, 3])

          #expect(try first.next()?[0].integerValue == 2)
          #expect(try first.next()?[0].integerValue == 3)
          #expect(try first.next() == nil)
        }
        // Only one of the two statements fits under the SQL's key; the other was finalized.
        try connection.transaction { transaction in
          #expect(transaction.base.statements.idleStatementCount == 1)
        }
      }
    }

    @Test
    func aCursorDroppedPartwayLeavesItsStatementAtTheStart() throws {
      try withNumbers { connection in
        try connection.transaction { transaction in
          do {
            var cursor = try transaction.rowCursor(numbers)
            #expect(try cursor.next()?[0].integerValue == 1)
          }
          #expect(transaction.base.statements.idleStatementCount == 1)

          var cursor = try transaction.rowCursor(numbers)
          #expect(try cursor.collect { $0[0].integerValue } == [1, 2, 3])
        }
      }
    }

    @Test
    func aCursorOpenAcrossASchemaChangeIsNotCachedAfterIt() throws {
      try withNumbers { connection in
        try connection.transaction { transaction in
          let generation = transaction.base.statements.generation
          do {
            var cursor = try transaction.rowCursor(numbers)
            #expect(try cursor.next()?[0].integerValue == 1)

            try transaction.execute("CREATE TABLE u (b INTEGER)")
            #expect(transaction.base.statements.generation != generation)

            #expect(try cursor.collect { $0[0].integerValue } == [2, 3])
          }
          // The cursor's statement was compiled before the change, so it was finalized rather
          // than given back.
          #expect(transaction.base.statements.idleStatementCount == 0)
        }
      }
    }

    private let numbers: SQL = "SELECT a FROM t ORDER BY a"

    /// Runs `body` with an in-memory connection whose table `t` holds 1, 2 and 3.
    private func withNumbers(_ body: (borrowing SQLiteWriteConnection) throws -> Void) throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.executeScript(
          "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1), (2), (3)"
        )
        try body(connection)
      }
    }
  }
#endif
