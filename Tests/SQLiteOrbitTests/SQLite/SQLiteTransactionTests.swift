#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  private func openTestConnection() throws -> SQLiteConnection {
    let connection = try SQLiteConnection.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .default
    )
    try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
    return connection
  }

  @Test
  func aCursorAdvancesLazilyAndStaysExhausted() throws {
    var connection = try openTestConnection()
    try connection.write { transaction in
      for id in 1...3 {
        try transaction.execute("INSERT INTO items VALUES (\(id), \("item \(id)"))")
      }
    }

    try connection.read { transaction in
      var cursor = try transaction.fetchCursor(
        "SELECT id, title FROM items ORDER BY id",
        as: Item.self
      )
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
  func lastInsertedRowIDReportsTheRowidSQLiteChose() throws {
    var connection = try openTestConnection()
    let (before, first, second, afterDelete) = try connection.write {
      transaction -> (Int64, Int64, Int64, Int64) in
      // A connection that has never inserted has no rowid to report.
      let before = transaction.lastInsertedRowID
      try transaction.execute("INSERT INTO items (title) VALUES ('a')")
      let first = transaction.lastInsertedRowID
      try transaction.execute("INSERT INTO items (title) VALUES ('b')")
      let second = transaction.lastInsertedRowID
      // A statement that inserts nothing leaves the previous rowid in place.
      try transaction.execute("DELETE FROM items WHERE id = \(1)")
      return (before, first, second, transaction.lastInsertedRowID)
    }
    #expect(before == 0)
    #expect(first == 1)
    #expect(second == 2)
    #expect(afterDelete == 2)
  }

  @Test
  func transactionsExposeTheRawConnectionAndItsLibrary() throws {
    var connection = try openTestConnection()
    try connection.write { transaction in
      try transaction.execute("INSERT INTO items VALUES (1, 'raw')")
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

  @OrbitRow
  private struct Item: Equatable, Sendable {
    let id: Int
    let title: String
  }
#endif
