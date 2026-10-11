#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import StructuredQueries
    import Testing

    @testable import SQLiteOrbit

    private func openTestConnection(
      configuration: SQLiteConfiguration = .default
    ) throws -> SQLiteConnection {
      let connection = try SQLiteConnection.open(
        path: ":memory:",
        flags: [.readWrite, .create, .memory, .noMutex],
        configuration: configuration
      )
      try connection.execute(
        """
        CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
        """
      )
      return connection
    }

    @Test
    func cursorsAdvanceLazilyAndStopWhenExhausted() throws {
      var connection = try openTestConnection()
      try connection.write { transaction in
        for id in 1...3 {
          try Item.insert { Item(id: id, title: "item \(id)") }.execute(transaction)
        }
      }

      try connection.read { transaction in
        var cursor = try Item.all.order { $0.id }.fetchCursor(transaction)
        var titles: [String] = []
        while let item = try cursor.next() {
          titles.append(item.title)
        }
        #expect(titles == ["item 1", "item 2", "item 3"])
        // A cursor that has reported the end keeps reporting it.
        #expect(try cursor.next() == nil)
      }
    }

    @Test
    func writeCursorsReturnRowsFromReturningClauses() throws {
      var connection = try openTestConnection()
      try connection.write { transaction in
        try Item.insert { Item(id: 1, title: "before") }.execute(transaction)
      }

      let updated = try connection.write { transaction in
        try #sql("UPDATE items SET title = 'after' RETURNING id", as: Int.self)
          .fetchAll(transaction)
      }
      #expect(updated == [1])

      let titles = try connection.read { transaction in
        try Item.select(\.title).fetchAll(transaction)
      }
      #expect(titles == ["after"])
    }

    @Test
    func changesCountForgetsWhatTheStatementBeforeTheLastOneChanged() throws {
      var connection = try openTestConnection()
      let counts = try connection.write { transaction -> [Int] in
        var counts: [Int] = []
        try #sql("INSERT INTO items (id, title) VALUES (1, 'a'), (2, 'b'), (3, 'c')", as: Void.self)
          .execute(transaction)
        counts.append(transaction.changesCount)
        try Item.where { $0.id.eq(1) }.delete().execute(transaction)
        counts.append(transaction.changesCount)
        return counts
      }
      #expect(counts == [3, 1])
    }

    @Test
    func lastInsertedRowIDReportsTheRowidSQLiteChose() throws {
      var connection = try openTestConnection()
      let (before, first, second, afterDelete) = try connection.write {
        transaction -> (Int64, Int64, Int64, Int64) in
        // A connection that has never inserted has no rowid to report.
        let before = transaction.lastInsertedRowID
        try #sql("INSERT INTO items (title) VALUES ('a')", as: Void.self).execute(transaction)
        let first = transaction.lastInsertedRowID
        try #sql("INSERT INTO items (title) VALUES ('b')", as: Void.self).execute(transaction)
        let second = transaction.lastInsertedRowID
        // A statement that inserts nothing leaves the previous rowid in place.
        try Item.where { $0.id.eq(1) }.delete().execute(transaction)
        return (before, first, second, transaction.lastInsertedRowID)
      }
      #expect(before == 0)
      #expect(first == 1)
      #expect(second == 2)
      #expect(afterDelete == 2)
    }

    @Test
    func bindingsAndColumnsRoundTripPrimitivesAndBlobs() throws {
      var connection = try openTestConnection()
      try connection.execute(
        """
        CREATE TABLE primitives (
          id INTEGER PRIMARY KEY, amount REAL, flag INTEGER, payload BLOB, missing TEXT
        )
        """
      )

      let payload: [UInt8] = [0x00, 0x01, 0xfe, 0xff]
      try connection.write { transaction in
        try #sql(
          """
          INSERT INTO primitives (id, amount, flag, payload, missing)
          VALUES (1, \(2.5, as: Double.self), \(true, as: Bool.self), \(payload, as: [UInt8].self), NULL)
          """,
          as: Void.self
        )
        .execute(transaction)
      }

      try connection.read { transaction in
        let amounts = try #sql("SELECT amount FROM primitives", as: Double.self)
          .fetchAll(transaction)
        #expect(amounts == [2.5])
        let flags = try #sql("SELECT flag FROM primitives", as: Bool.self).fetchAll(transaction)
        #expect(flags == [true])
        let payloads = try #sql("SELECT payload FROM primitives", as: [UInt8].self)
          .fetchAll(transaction)
        #expect(payloads == [payload])
        let missing = try #sql("SELECT missing FROM primitives", as: String?.self)
          .fetchAll(transaction)
        #expect(missing == [String?.none])
      }
    }

    @Test
    func anEmptyBlobRoundTripsAsABlobRatherThanNull() throws {
      var connection = try openTestConnection()
      try connection.execute("CREATE TABLE blobs (payload BLOB)")

      let empty: [UInt8] = []
      try connection.write { transaction in
        try #sql(
          "INSERT INTO blobs (payload) VALUES (\(empty, as: [UInt8].self))",
          as: Void.self
        )
        .execute(transaction)
      }

      try connection.read { transaction in
        let types = try #sql("SELECT typeof(payload) FROM blobs", as: String.self)
          .fetchAll(transaction)
        #expect(types == ["blob"])
        let payloads = try #sql("SELECT payload FROM blobs", as: [UInt8].self).fetchAll(transaction)
        #expect(payloads == [[]])
      }
    }

    @Test
    func cursorsGiveTheirStatementBackToTheCache() throws {
      let counters = TestCounter()
      let base = builtInTestLibrary
      var configuration = SQLiteConfiguration.default
      configuration.library = base
      // Only the fetches count. The transaction's own statements, such as its BEGIN and ROLLBACK and
      // the check that the schema is unchanged, are not the cache's.
      configuration.library.statements.preparation.prepare = {
        connection,
        sql,
        byteCount,
        flags,
        statement,
        tail in
        if let sql, String(cString: sql).hasPrefix(#"SELECT "items""#) {
          counters.increment()
        }
        return base.statements.preparation.prepare(
          connection,
          sql,
          byteCount,
          flags,
          statement,
          tail
        )
      }

      var connection = try openTestConnection(configuration: configuration)
      try connection.write { transaction in
        try Item.insert { Item(id: 1, title: "cached") }.execute(transaction)
      }

      try connection.read { transaction in
        for _ in 0..<10 {
          _ = try Item.all.fetchAll(transaction)
        }
      }

      // Ten identical fetches, one parse: each cursor returned its statement when it went out of
      // scope, and the next fetch found it waiting.
      #expect(counters.value == 1)
    }

    @Test
    func schemaChangesInvalidateCachedStatements() throws {
      let preparations = TestCounter()
      let base = builtInTestLibrary
      var configuration = SQLiteConfiguration.default
      configuration.library = base
      configuration.library.statements.preparation.prepare = {
        connection,
        sql,
        byteCount,
        flags,
        statement,
        tail in
        if let sql, String(cString: sql).hasPrefix("SELECT title FROM current_items") {
          preparations.increment()
        }
        return base.statements.preparation.prepare(
          connection,
          sql,
          byteCount,
          flags,
          statement,
          tail
        )
      }

      var connection = try openTestConnection(configuration: configuration)
      try connection.write { transaction in
        try transaction.execute("INSERT INTO items VALUES (1, 'Original')")
        try transaction.executeScript(
          """
          CREATE TABLE alternate_items (title TEXT NOT NULL);
          INSERT INTO alternate_items VALUES ('Alternate');
          CREATE VIEW current_items AS SELECT title FROM items;
          """
        )
      }

      let original = try connection.read { transaction in
        try #sql("SELECT title FROM current_items", as: String.self).fetchAll(transaction)
      }
      try connection.write { transaction in
        try transaction.executeScript(
          """
          DROP VIEW current_items;
          CREATE VIEW current_items AS SELECT title FROM alternate_items;
          """
        )
      }
      let alternate = try connection.read { transaction in
        try #sql("SELECT title FROM current_items", as: String.self).fetchAll(transaction)
      }

      #expect(original == ["Original"])
      #expect(alternate == ["Alternate"])
      #expect(preparations.value == 2)
    }

    @Test
    func transactionsExposeTheRawConnectionAndItsLibrary() throws {
      var connection = try openTestConnection()
      try connection.write { transaction in
        try Item.insert { Item(id: 1, title: "raw") }.execute(transaction)
      }

      let count = try connection.read { transaction -> Int64 in
        // Exactly what a caller with their own SQLite build would do.
        let library = transaction.sqlite
        var statement: OpaquePointer?
        let code = "SELECT count(*) FROM items"
          .withCString {
            library.statements.preparation.prepare(
              transaction.sqliteConnection,
              $0,
              -1,
              0,
              &statement,
              nil
            )
          }
        try #require(code == SQLiteResultCode.ok.rawValue)
        defer { _ = library.statements.execution.finalize(statement) }
        try #require(library.statements.execution.step(statement) == SQLiteResultCode.row.rawValue)
        return library.columns.int64(statement, 0)
      }
      #expect(count == 1)
    }

    @Table
    private struct Item: Equatable, Sendable {
      let id: Int
      var title: String
    }
  #endif
#endif
