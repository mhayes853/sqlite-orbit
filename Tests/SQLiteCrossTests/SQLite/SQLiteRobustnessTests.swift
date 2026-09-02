#if SystemSQLite
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteCross

  private func openConnection(
    configuration: SQLiteConfiguration = .default
  ) throws -> SQLiteHandle {
    let handle = try SQLiteHandle.open(
      path: ":memory:",
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: configuration
    )
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
    return handle
  }

  @Test
  func textBindingsKeepEverythingAfterAnEmbeddedNul() throws {
    let handle = try openConnection()
    let awkward = "before\u{0}after"

    try handle.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: awkward) })
    }

    let titles = try handle.read { transaction in
      try transaction.fetchAll(Item.select(\.title))
    }
    // Binding with a byte count of -1 asks SQLite to stop at the first NUL, which would silently
    // truncate this to "before".
    #expect(titles == [awkward])
  }

  @Test
  func rawSQLStopsAtAnEmbeddedNulTheWaySQLiteDoes() throws {
    let handle = try openConnection()
    try handle.execute(
      "INSERT INTO items (id, title) VALUES (1, 'a');\u{0}INSERT INTO items (id, title) VALUES (2, 'b')"
    )
    let count = try handle.read { transaction in
      try transaction.fetchAll(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    // SQLite reads SQL text up to the first NUL whatever length it is given, so the second
    // statement here is not run. Values are a different matter: those keep their NULs, which is
    // what `textBindingsKeepEverythingAfterAnEmbeddedNul` pins down.
    #expect(count == [1])
  }

  @Test
  func aReadOnAWritableConnectionRefusesToMutate() throws {
    let handle = try openConnection()

    // The connection can write, but not while lending a read transaction: a mutation that was
    // merely rolled back at the end of the read would look like it had worked.
    #expect(throws: SQLiteError.self) {
      try handle.read { transaction in
        try transaction.execute("INSERT INTO items (id, title) VALUES (1, 'nope')")
      }
    }

    // And the connection is writable again afterwards.
    try handle.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "yes") })
    }
    let titles = try handle.read { transaction in
      try transaction.fetchAll(Item.select(\.title))
    }
    #expect(titles == ["yes"])
  }

  @Test
  func aFailedReadRestoresTheConnectionToWritable() throws {
    let handle = try openConnection()

    struct Abort: Error {}
    #expect(throws: Abort.self) {
      try handle.read { _ in throw Abort() }
    }

    // A read that threw still turned `query_only` back off on its way out.
    try handle.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "after failure") })
    }
    let titles = try handle.read { transaction in
      try transaction.fetchAll(Item.select(\.title))
    }
    #expect(titles == ["after failure"])
  }

  @Test
  func aStatementIsReusableAfterTheQueryUsingItFails() throws {
    let handle = try openConnection()
    try handle.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "kept") })
    }

    // Decoding the title as an integer fails partway through the cursor's life.
    try handle.read { transaction in
      #expect(throws: (any Error).self) {
        _ = try transaction.fetchAll(#sql("SELECT title FROM items", as: Int.self))
      }
    }

    // The statement went back to the cache in a usable state rather than mid-scan.
    let titles = try handle.read { transaction in
      try transaction.fetchAll(Item.select(\.title))
    }
    #expect(titles == ["kept"])
  }

  @Test
  func aPartiallyReadCursorDoesNotResumeWhenItsStatementIsReused() throws {
    let handle = try openConnection()
    try handle.write { transaction in
      for id in 1...3 {
        try transaction.execute(Item.insert { Item(id: id, title: "item \(id)") })
      }
    }

    try handle.read { transaction in
      // Abandon the cursor after one row, so its statement goes back to the cache mid-scan.
      var cursor = try transaction.fetchCursor(Item.all.order { $0.id })
      _ = try cursor.next()
    }

    let titles = try handle.read { transaction in
      try transaction.fetchAll(Item.all.order { $0.id }).map(\.title)
    }
    // A statement that was not reset would start from the second row.
    #expect(titles == ["item 1", "item 2", "item 3"])
  }

  @Test
  func aCacheThatHoldsNothingStillRunsQueries() throws {
    var configuration = SQLiteConfiguration.default
    configuration.maximumCachedStatements = 0
    let handle = try openConnection(configuration: configuration)

    try handle.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "uncached") })
    }
    let titles = try handle.read { transaction in
      try transaction.fetchAll(Item.select(\.title))
    }
    #expect(titles == ["uncached"])
  }

  @Test
  func largeIntegersRoundTripWithoutLosingPrecision() throws {
    let handle = try openConnection()
    try handle.execute("CREATE TABLE numbers (value INTEGER)")

    let extremes: [Int64] = [.min, -1, 0, 1, .max]
    for value in extremes {
      try handle.write { transaction in
        try transaction.execute(
          #sql("INSERT INTO numbers (value) VALUES (\(value, as: Int64.self))", as: Void.self)
        )
      }
    }

    let stored = try handle.read { transaction in
      try transaction.fetchAll(#sql("SELECT value FROM numbers", as: Int64.self))
    }
    #expect(stored == extremes)
  }

  @Test
  func anUnsignedValueTooLargeForSQLiteIsReportedRatherThanWrapped() throws {
    let handle = try openConnection()
    try handle.execute("CREATE TABLE numbers (value INTEGER)")

    // SQLite stores signed 64-bit integers, so this cannot be represented.
    #expect(throws: DatabaseIntegerOverflowError<UInt64>.self) {
      try handle.write { transaction in
        try transaction.execute(
          #sql(
            "INSERT INTO numbers (value) VALUES (\(UInt64.max))",
            as: Void.self
          )
        )
      }
    }
  }

  @Test
  func aFailedBindingLeavesTheCacheUsable() throws {
    let handle = try openConnection()
    try handle.execute("CREATE TABLE numbers (value INTEGER)")

    for _ in 0..<3 {
      #expect(throws: (any Error).self) {
        try handle.write { transaction in
          try transaction.execute(
            #sql(
              "INSERT INTO numbers (value) VALUES (\(UInt64.max))",
              as: Void.self
            )
          )
        }
      }
    }

    // The statement that failed to bind was given back, so the cache did not leak it.
    try handle.write { transaction in
      try transaction.execute(
        #sql("INSERT INTO numbers (value) VALUES (\(1, as: Int.self))", as: Void.self)
      )
    }
    let stored = try handle.read { transaction in
      try transaction.fetchAll(#sql("SELECT value FROM numbers", as: Int.self))
    }
    #expect(stored == [1])
  }

  @Test
  func textWithMultiByteCharactersRoundTrips() throws {
    let handle = try openConnection()
    let titles = ["Blob’s reminder", "日本語", "🧑‍🚀 emoji", ""]

    try handle.write { transaction in
      for (id, title) in titles.enumerated() {
        try transaction.execute(Item.insert { Item(id: id + 1, title: title) })
      }
    }
    let stored = try handle.read { transaction in
      try transaction.fetchAll(Item.all.order { $0.id }).map(\.title)
    }
    #expect(stored == titles)
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }
#endif
