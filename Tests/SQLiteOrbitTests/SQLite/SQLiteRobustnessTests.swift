#if SystemSQLite
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteOrbit

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

  /// Counts connections opened and closed, so a leak is visible rather than merely suspected.
  private final class ConnectionCounter: Sendable {
    private let state = Mutex((opened: 0, closed: 0))

    var opened: Int { state.withLock { $0.opened } }
    var closed: Int { state.withLock { $0.closed } }

    var library: SQLiteLibrary {
      let base = SQLiteLibrary.system
      var library = base
      library.open_v2 = { path, connection, flags, vfs in
        let code = base.open_v2(path, connection, flags, vfs)
        if code == SQLiteResultCode.ok.rawValue {
          self.state.withLock { $0.opened += 1 }
        }
        return code
      }
      library.close_v2 = { connection in
        self.state.withLock { $0.closed += 1 }
        return base.close_v2(connection)
      }
      return library
    }
  }

  @Test
  func releasingAPoolClosesEveryConnectionItOpened() async throws {
    let counter = ConnectionCounter()
    var configuration = SQLiteConfiguration.default
    configuration.library = counter.library
    configuration.readerCount = 3

    let path = temporaryDatabasePath("close")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }

    do {
      let driver = try SQLitePool(path: DatabasePath(path), configuration: configuration)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      #expect(counter.opened == 4)
      #expect(counter.closed == 0)
    }

    // Nothing else holds these connections, so every one of them must have been closed. A driver
    // that leaked them would exhaust file descriptors in any process that opens databases often.
    while counter.closed < counter.opened {
      await Task.yield()
    }
    #expect(counter.closed == counter.opened)
  }

  @Test
  func aPoolSurvivesAStormOfCancellations() async throws {
    let path = temporaryDatabasePath("storm")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    var configuration = SQLiteConfiguration.default
    configuration.readerCount = 2
    let driver = try SQLitePool(path: DatabasePath(path), configuration: configuration)
    try await driver.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }

    // Half of these are cancelled almost immediately, most while still queued for a reader or the
    // writer. Whatever they were holding has to come back either way.
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<200 {
        group.addTask {
          let task = Task {
            if index.isMultiple(of: 2) {
              _ = try await driver.read { transaction in
                try transaction.fetchAll(#sql("SELECT count(*) FROM items", as: Int.self))
              }
            } else {
              try await driver.write { transaction in
                try transaction.execute("INSERT INTO items (id) VALUES (NULL)")
              }
            }
          }
          if index.isMultiple(of: 3) {
            task.cancel()
          }
          _ = try? await task.value
        }
      }
      await group.waitForAll()
    }

    // Every reader and the writer came back, so the pool still works.
    let count = try await driver.read { transaction in
      try transaction.fetchAll(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    #expect(count.count == 1)
    try await driver.write { transaction in
      try transaction.execute("INSERT INTO items (id) VALUES (NULL)")
    }
  }

  @Test
  func cancelledWritesNeverCommitWithoutReturningSuccess() async throws {
    let path = temporaryDatabasePath("cancelled-commits")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let driver = try SQLitePool(path: DatabasePath(path))
    try await driver.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }

    let writes = (1...300)
      .map { id in
        Task {
          try await driver.write { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (\(id))")
            return id
          }
        }
      }
    for (offset, write) in writes.enumerated() where offset.isMultiple(of: 2) {
      write.cancel()
    }

    var successfulIDs: [Int] = []
    for write in writes {
      if let id = try? await write.value {
        successfulIDs.append(id)
      }
    }
    let storedIDs = try await driver.read { transaction in
      try transaction.fetchAll(#sql("SELECT id FROM items ORDER BY id", as: Int.self))
    }

    // Cancellation may win or lose a race with a fast write, but a committed transaction must
    // always be reported as successful and a failed one must leave no row behind.
    #expect(storedIDs == successfulIDs.sorted())
  }

  @Test
  func aReaderSeesWhatAnotherConnectionCommitted() async throws {
    let path = temporaryDatabasePath("shared")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }

    // Two drivers on one file stand in for two processes sharing a database.
    let writer = try SQLitePool(path: DatabasePath(path))
    let reader = try SQLitePool(path: DatabasePath(path))
    try await writer.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }

    for id in 1...5 {
      try await writer.write { transaction in
        try transaction.execute("INSERT INTO items (id) VALUES (\(id))")
      }
      // Each read takes a fresh snapshot, so it must see everything committed before it.
      let count = try await reader.read { transaction in
        try transaction.fetchAll(#sql("SELECT count(*) FROM items", as: Int.self))
      }
      #expect(count == [id])
    }
  }

  @Test
  func writesFromTwoConnectionsQueueRatherThanFail() async throws {
    let path = temporaryDatabasePath("contended")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }

    let first = try SQLitePool(path: DatabasePath(path))
    let second = try SQLitePool(path: DatabasePath(path))
    try await first.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }

    // Each driver serializes its own writes, but nothing coordinates the two: they overlap in
    // SQLite itself, and only the busy timeout keeps one from failing outright.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<60 {
        let driver = index.isMultiple(of: 2) ? first : second
        group.addTask {
          try await driver.write { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (NULL)")
          }
        }
      }
      try await group.waitForAll()
    }

    let count = try await first.read { transaction in
      try transaction.fetchAll(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    #expect(count == [60])
  }

  @Test
  func decodingNullIntoANonOptionalIsReportedRatherThanCrashing() throws {
    let handle = try openConnection()
    try handle.execute("CREATE TABLE numbers (value INTEGER)")
    try handle.write { transaction in
      try transaction.execute("INSERT INTO numbers (value) VALUES (NULL)")
    }

    #expect(throws: (any Error).self) {
      try handle.read { transaction in
        _ = try transaction.fetchAll(#sql("SELECT value FROM numbers", as: Int.self))
      }
    }

    // The failed decode did not leave the connection unusable.
    let values = try handle.read { transaction in
      try transaction.fetchAll(#sql("SELECT value FROM numbers", as: Int?.self))
    }
    #expect(values == [Int?.none])
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }

  /// A cancellation interrupts whichever statement is running, and the interrupt stays armed
  /// through the one that ends the transaction. Leaving that transaction open would fail the next
  /// access on the connection rather than this one.
  @Test
  func aTransactionInterruptedWhileItEndsIsNotLeftOpen() throws {
    let base = SQLiteLibrary.system
    let isArmed = Mutex(true)
    var configuration = SQLiteConfiguration.default
    configuration.library.step = { statement in
      let sql = base.sql(statement).map { String(cString: $0) }
      guard sql == "ROLLBACK", isArmed.withLock({ $0 }) else { return base.step(statement) }
      isArmed.withLock { $0 = false }
      return SQLiteResultCode.interrupt.rawValue
    }
    let handle = try openConnection(configuration: configuration)

    // The read's own rollback is interrupted, and that failure is reported...
    #expect(throws: SQLiteError.self) {
      try handle.read { _ in }
    }

    // ...but it left no transaction behind for the next access to trip over.
    #expect(isArmed.withLock { !$0 })
    try handle.write { transaction in
      try transaction.execute("INSERT INTO items (id, title) VALUES (1, 'after')")
    }
    let titles = try handle.read { transaction in
      try transaction.fetchAll(#sql("SELECT title FROM items", as: String.self))
    }
    #expect(titles == ["after"])
  }

  /// `Int` is 32 bits wide on arm64_32, so this value does not fit there and used to trap on the
  /// way out of the decoder. It still decodes wherever `Int` is 64 bits, which is where this runs.
  @Test
  func aValueTooLargeForA32BitIntIsReportedRatherThanTrapping() throws {
    let handle = try openConnection()
    try handle.execute("CREATE TABLE numbers (value INTEGER)")
    try handle.write { transaction in
      try transaction.execute(
        #sql("INSERT INTO numbers (value) VALUES (\(Int64.max, as: Int64.self))", as: Void.self)
      )
    }

    let asInt64 = try handle.read { transaction in
      try transaction.fetchAll(#sql("SELECT value FROM numbers", as: Int64.self))
    }
    #expect(asInt64 == [Int64.max])

    let asInt = try handle.read { transaction in
      try Result { try transaction.fetchAll(#sql("SELECT value FROM numbers", as: Int.self)) }
    }
    if Int.bitWidth == 64 {
      #expect(try asInt.get() == [Int(Int64.max)])
    } else {
      #expect(throws: DatabaseIntegerOverflowError<Int64>.self) { try asInt.get() }
    }
  }
#endif
