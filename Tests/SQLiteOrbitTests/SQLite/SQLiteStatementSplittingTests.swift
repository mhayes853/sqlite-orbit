#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteStatementSplittingTests {
    @Test
    func aScriptSplitsWhereSQLiteEndsEachStatementAndRunsInTurn() throws {
      // The later statements name a table the first creates, so each is run before the next is
      // split off, and the semicolons in the string and the trigger body do not end a statement.
      let script = """
        CREATE TABLE items (a INTEGER, label TEXT);
        INSERT INTO items VALUES (1, 'semi;colon'); -- a trailing comment
        CREATE TRIGGER doubled AFTER INSERT ON items WHEN new.a < 10 BEGIN
          INSERT INTO items VALUES (new.a * 10, 'trigger;');
        END;
        /* before */ INSERT INTO items VALUES (2, 'héllo 日本');
        -- nothing after this
        """
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let statements = try owner.write { transaction in
        var statements = [String]()
        var remaining = script[...]
        while let split = try transaction.firstStatement(in: remaining) {
          try transaction.execute(split.statement)
          statements.append(split.statement.text)
          remaining = split.remainder
        }
        #expect(remaining == "\n-- nothing after this")
        return statements
      }

      #expect(
        statements == [
          "CREATE TABLE items (a INTEGER, label TEXT);",
          "\nINSERT INTO items VALUES (1, 'semi;colon');",
          """
           -- a trailing comment
          CREATE TRIGGER doubled AFTER INSERT ON items WHEN new.a < 10 BEGIN
            INSERT INTO items VALUES (new.a * 10, 'trigger;');
          END;
          """,
          "\n/* before */ INSERT INTO items VALUES (2, 'héllo 日本');"
        ]
      )
      #expect(statements.joined() + "\n-- nothing after this" == script)
      let labels = try owner.read { transaction in
        try transaction.fetchAll("SELECT label FROM items ORDER BY a", as: String.self)
      }
      #expect(labels == ["semi;colon", "héllo 日本", "trigger;"])
    }

    @Test(arguments: ["", "   ", "-- only a comment", ";;", " ; /* empty */ ;\n"])
    func sqlHoldingNoStatementHasNoFirstStatement(sql: String) throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.read { transaction in
        let split = try transaction.firstStatement(in: sql)
        #expect(split == nil)
      }
    }

    @Test
    func emptyStatementsBeforeTheFirstArePartOfItsText() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.read { transaction in
        let split = try #require(try transaction.firstStatement(in: " ; -- c\nSELECT 1; SELECT 2"))
        #expect(split.statement.text == " ; -- c\nSELECT 1;")
        #expect(split.remainder == " SELECT 2")
      }
    }

    @Test
    func splittingCompilesWithoutRunningEvenAStatementThatWrites() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.write { try $0.execute("CREATE TABLE items (a INTEGER)") }
      try owner.read { transaction in
        let split = try transaction.firstStatement(in: "INSERT INTO items VALUES (1); SELECT 1")
        #expect(split?.statement.text == "INSERT INTO items VALUES (1);")
        #expect(try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self) == 0)
      }
    }

    @Test
    func aStatementThatDoesNotCompileFailsToSplit() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.read { transaction in
        let missing = #expect(throws: SQLiteError.self) {
          try transaction.firstStatement(in: "SELECT * FROM missing; SELECT 1")
        }
        #expect(missing?.message?.contains("no such table") == true)
        #expect(throws: SQLiteError.self) { try transaction.firstStatement(in: "SELEC 1") }
      }
    }

    @Test
    func connectionsAndConnectionAccessSplitToo() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let fromAccess = try owner.withConnectionAccess { connection in
        try connection.firstStatement(in: "SELECT 1; SELECT 2")
      }
      #expect(fromAccess?.statement.text == "SELECT 1;")
      #expect(fromAccess?.remainder == " SELECT 2")

      let queue = try SQLiteQueue(path: .memory)
      let fromReader = try queue.readWithoutTransactionBlocking { connection in
        try connection.firstStatement(in: "SELECT 1; SELECT 2")?.statement.text
      }
      let fromWriter = try queue.writeWithoutTransactionBlocking { connection in
        try connection.firstStatement(in: "SELECT 1; SELECT 2")?.statement.text
      }
      #expect(fromReader == "SELECT 1;")
      #expect(fromWriter == "SELECT 1;")
    }
  }
#endif
