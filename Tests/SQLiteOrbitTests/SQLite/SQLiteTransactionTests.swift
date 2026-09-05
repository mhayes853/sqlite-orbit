#if SystemSQLite
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteOrbit

  private func openTestConnection(
    configuration: SQLiteConfiguration = .default
  ) throws -> SQLiteHandle {
    let connection = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    try connection.execute(
      """
      CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
      CREATE TABLE special_values (
        id INTEGER PRIMARY KEY,
        occurredAt TEXT NOT NULL,
        token TEXT NOT NULL
      );
      """
    )
    return connection
  }

  @Test
  func transactionExecutesStatementsAndDecodesTables() throws {
    let connection = try openTestConnection()

    let changed = try connection.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "Blob's reminder") })
    }
    #expect(changed == 1)

    let items = try connection.read { transaction in
      try transaction.fetchAll(Item.all.order { $0.id })
    }
    #expect(items == [Item(id: 1, title: "Blob's reminder")])
  }

  @Test
  func transactionDecodesTupleProjections() throws {
    let connection = try openTestConnection()
    try connection.write { transaction in
      try transaction.execute(Item.insert { Item(id: 7, title: "projected") })
    }

    let projections = try connection.read { transaction in
      try transaction.fetchAll(Item.select { ($0.id, $0.title) })
    }
    #expect(projections.count == 1)
    #expect(projections[0].0 == 7)
    #expect(projections[0].1 == "projected")
  }

  @Test
  func cursorsAdvanceLazilyAndStopWhenExhausted() throws {
    let connection = try openTestConnection()
    try connection.write { transaction in
      for id in 1...3 {
        try transaction.execute(Item.insert { Item(id: id, title: "item \(id)") })
      }
    }

    try connection.read { transaction in
      var cursor = try transaction.fetchCursor(Item.all.order { $0.id })
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
    let connection = try openTestConnection()
    try connection.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "before") })
    }

    let updated = try connection.write { transaction in
      try transaction.fetchAll(
        #sql("UPDATE items SET title = 'after' RETURNING id", as: Int.self)
      )
    }
    #expect(updated == [1])

    let titles = try connection.read { transaction in
      try transaction.fetchAll(Item.select(\.title))
    }
    #expect(titles == ["after"])
  }

  @Test
  func executeReportsTheNumberOfChangedRows() throws {
    let connection = try openTestConnection()
    try connection.write { transaction in
      for id in 1...3 {
        try transaction.execute(Item.insert { Item(id: id, title: "row") })
      }
    }

    let changed = try connection.write { transaction in
      try transaction.execute(Item.update { $0.title = "changed" })
    }
    #expect(changed == 3)
  }

  @Test
  func bindingsAndColumnsRoundTripDatesAndUUIDs() throws {
    let connection = try openTestConnection()
    let occurredAt = Date(timeIntervalSince1970: 1_234_567_890)
    let token = UUID()

    try connection.write { transaction in
      try transaction.execute(
        SpecialValue.insert { SpecialValue(id: 1, occurredAt: occurredAt, token: token) }
      )
    }

    let values = try connection.read { transaction in
      try transaction.fetchAll(SpecialValue.all)
    }
    #expect(values.count == 1)
    #expect(values[0].token == token)
    // The stored spelling has second precision at minimum, so compare at that resolution.
    #expect(
      abs(values[0].occurredAt.timeIntervalSince(occurredAt)) < 0.001
    )
  }

  @Test
  func bindingsAndColumnsRoundTripPrimitivesAndBlobs() throws {
    let connection = try openTestConnection()
    try connection.execute(
      """
      CREATE TABLE primitives (
        id INTEGER PRIMARY KEY, amount REAL, flag INTEGER, payload BLOB, missing TEXT
      )
      """
    )

    let payload: [UInt8] = [0x00, 0x01, 0xfe, 0xff]
    try connection.write { transaction in
      try transaction.execute(
        #sql(
          """
          INSERT INTO primitives (id, amount, flag, payload, missing)
          VALUES (1, \(2.5, as: Double.self), \(true, as: Bool.self), \(payload, as: [UInt8].self), NULL)
          """,
          as: Void.self
        )
      )
    }

    try connection.read { transaction in
      let amounts = try transaction.fetchAll(#sql("SELECT amount FROM primitives", as: Double.self))
      #expect(amounts == [2.5])
      let flags = try transaction.fetchAll(#sql("SELECT flag FROM primitives", as: Bool.self))
      #expect(flags == [true])
      let payloads = try transaction.fetchAll(
        #sql("SELECT payload FROM primitives", as: [UInt8].self)
      )
      #expect(payloads == [payload])
      let missing = try transaction.fetchAll(
        #sql("SELECT missing FROM primitives", as: String?.self)
      )
      #expect(missing == [String?.none])
    }
  }

  @Test
  func anEmptyBlobRoundTripsAsABlobRatherThanNull() throws {
    let connection = try openTestConnection()
    try connection.execute("CREATE TABLE blobs (payload BLOB)")

    let empty: [UInt8] = []
    try connection.write { transaction in
      try transaction.execute(
        #sql(
          "INSERT INTO blobs (payload) VALUES (\(empty, as: [UInt8].self))",
          as: Void.self
        )
      )
    }

    try connection.read { transaction in
      let types = try transaction.fetchAll(
        #sql("SELECT typeof(payload) FROM blobs", as: String.self)
      )
      #expect(types == ["blob"])
      let payloads = try transaction.fetchAll(#sql("SELECT payload FROM blobs", as: [UInt8].self))
      #expect(payloads == [[]])
    }
  }

  @Test
  func cursorsGiveTheirStatementBackToTheCache() throws {
    let counters = Mutex(0)
    let base = SQLiteLibrary.system
    var configuration = SQLiteConfiguration.default
    configuration.library = base
    // Only the fetches count; the transaction's own BEGIN and ROLLBACK are prepared uncached.
    configuration.library.prepare_v3 = { connection, sql, byteCount, flags, statement, tail in
      if let sql, String(cString: sql).hasPrefix("SELECT") {
        counters.withLock { $0 += 1 }
      }
      return base.prepare_v3(connection, sql, byteCount, flags, statement, tail)
    }

    let connection = try openTestConnection(configuration: configuration)
    try connection.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "cached") })
    }

    try connection.read { transaction in
      for _ in 0..<10 {
        _ = try transaction.fetchAll(Item.all)
      }
    }

    // Ten identical fetches, one parse: each cursor returned its statement when it went out of
    // scope, and the next fetch found it waiting.
    #expect(counters.withLock { $0 } == 1)
  }

  @Test
  func transactionsExposeTheRawConnectionAndItsLibrary() throws {
    let connection = try openTestConnection()
    try connection.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "raw") })
    }

    let count = try connection.read { transaction -> Int64 in
      // Exactly what a caller with their own SQLite build would do.
      let library = transaction.sqlite
      var statement: OpaquePointer?
      let code = "SELECT count(*) FROM items".withCString {
        library.prepare_v3(transaction.sqliteConnection, $0, -1, 0, &statement, nil)
      }
      try #require(code == SQLiteResultCode.ok.rawValue)
      defer { _ = library.finalize(statement) }
      try #require(library.step(statement) == SQLiteResultCode.row.rawValue)
      return library.column_int64(statement, 0)
    }
    #expect(count == 1)
  }

  @Test
  func decodingReportsATypeMismatchRatherThanReturningGarbage() throws {
    let connection = try openTestConnection()
    try connection.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "text") })
    }

    #expect(throws: (any Error).self) {
      try connection.read { transaction in
        _ = try transaction.fetchAll(#sql("SELECT title FROM items", as: Int.self))
      }
    }
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }

  @Table("special_values")
  private struct SpecialValue: Equatable, Sendable {
    let id: Int
    var occurredAt: Date
    var token: UUID
  }
#endif
