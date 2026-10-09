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
    func cachedStatementsFollowSchemaChangesMadeThroughExecute() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
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
        }
      }
    }

    @Test
    func cachedPragmasAndViewsTakeEffectEachTime() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        for version in [3, 4, 3] {
          try connection.execute("PRAGMA user_version = \(raw: String(version))")
          #expect(try connection.fetchOne("PRAGMA user_version", as: Int.self) == version)
        }
        try connection.transaction { transaction in
          try transaction.execute("CREATE TABLE a (x INTEGER)")
          try transaction.execute("CREATE TABLE b (x INTEGER)")
          try transaction.execute("INSERT INTO a VALUES (1)")
          try transaction.execute("INSERT INTO b VALUES (2)")
          try transaction.execute("CREATE VIEW v AS SELECT x FROM a")
          #expect(try transaction.fetchAll("SELECT x FROM v", as: Int.self) == [1])
          try transaction.execute("DROP VIEW v")
          try transaction.execute("CREATE VIEW v AS SELECT x FROM b")
          #expect(try transaction.fetchAll("SELECT x FROM v", as: Int.self) == [2])
        }
      }
    }

    @Test
    func aBindingFailureGivesTheCachedStatementBack() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.executeScript("CREATE TABLE t (a INTEGER)")
        try connection.transaction { transaction in
          try transaction.execute("INSERT INTO t VALUES (\(UInt64(1)))")
          #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
            try transaction.execute("INSERT INTO t VALUES (\(UInt64.max))")
          }
          try transaction.execute("INSERT INTO t VALUES (\(UInt64(2)))")
          #expect(transaction.base.statements.idleStatementCount == 1)
        }
        #expect(try connection.fetchAll("SELECT a FROM t ORDER BY a", as: Int.self) == [1, 2])
      }
    }

    @Test
    func aFailedStepLeavesTheStatementReusable() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.executeScript("CREATE TABLE t (a INTEGER PRIMARY KEY)")
        try connection.transaction { transaction in
          try transaction.execute("INSERT INTO t VALUES (\(1))")
          #expect(throws: SQLiteError.self) {
            try transaction.execute("INSERT INTO t VALUES (\(1))")
          }
          try transaction.execute("INSERT INTO t VALUES (\(2))")
        }
        #expect(try connection.fetchAll("SELECT a FROM t ORDER BY a", as: Int.self) == [1, 2])
      }
    }
  }
#endif
