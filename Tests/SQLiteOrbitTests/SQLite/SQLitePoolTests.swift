#if BuiltInSQLite
  import Foundation
  import StructuredQueries
  import Testing

  @testable import SQLiteOrbit

  /// Runs `body` with a pool on a database file of its own, holding the table `items`.
  private func withPool(
    readerCount: Int? = nil,
    _ body: (SQLitePool) async throws -> Void
  ) async throws {
    try await withTestDatabaseFile("pool") { file in
      var configuration = SQLiteConfiguration.default
      if let readerCount { configuration.readerCount = readerCount }
      let pool = try file.pool(configuration: configuration)
      try await pool.execute(
        sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
      )
      try await body(pool)
    }
  }

  @Test(arguments: [OrbitDatabasePath.memory, .temporary, ":memory:", ""])
  func poolRejectsDatabasesItCannotPool(path: OrbitDatabasePath) {
    #expect(throws: SQLitePoolUnavailableError.self) {
      _ = try SQLitePool(path: path)
    }
  }

  @Test
  func poolRunsInWALMode() async throws {
    try await withPool { pool throws in
      #expect(try await pool.pragma("journal_mode", as: String.self) == "wal")
    }
  }

  @Test
  func poolConnectionsReportTheConfigurationTheyWereGiven() async throws {
    try await withTestDatabaseFile("pool") { file in
      var configuration = SQLiteConfiguration.default
      configuration.setupSQL = ["PRAGMA cache_size = 100"]
      let pool = try file.pool(configuration: configuration)

      // The pool's own setup for each role stays out of what its transactions report.
      let readerSetup = try await pool.read { $0.configuration.setupSQL }
      let writerSetup = try await pool.write { $0.configuration.setupSQL }
      let connectionSetup = try await pool.writeWithoutTransaction { $0.configuration.setupSQL }
      #expect(readerSetup == ["PRAGMA cache_size = 100"])
      #expect(writerSetup == ["PRAGMA cache_size = 100"])
      #expect(connectionSetup == ["PRAGMA cache_size = 100"])
    }
  }

  @Test(arguments: [0, -1])
  func aNonpositiveReaderCountStillOpensOneReader(readerCount: Int) async throws {
    try await withTestDatabaseFile("pool") { file in
      let openedConnections = TestCounter()
      var configuration = SQLiteConfiguration.default
      configuration.readerCount = readerCount
      configuration.connectionSetups.append(
        SQLiteConnectionSetup { _ in
          openedConnections.increment()
          return SQLiteResultCode.ok.rawValue
        }
      )

      let pool = try file.pool(configuration: configuration)
      // One writer and one reader must have been configured, even for an invalid count.
      #expect(openedConnections.value == 2)
      #expect(try await pool.read { try $0.fetchOne(#sql("SELECT 1", as: Int.self)) } == 1)
    }
  }

  @Test
  func aPoolWithStatementCachingDisabledFinalizesEachQuery() async throws {
    let query = "SELECT title FROM items ORDER BY id"
    let prepared = TestCounter()
    let finalized = TestCounter()
    let preparedStatements = Lock<Set<UInt>>([])
    let base = builtInTestLibrary
    var library = base
    library.statements.preparation.prepare = { connection, sql, byteCount, flags, statement, tail in
      let code = base.statements.preparation.prepare(
        connection,
        sql,
        byteCount,
        flags,
        statement,
        tail
      )
      if code == SQLiteResultCode.ok.rawValue,
        let sql, String(cString: sql) == query,
        let pointer = statement?.pointee
      {
        _ = preparedStatements.withLock { $0.insert(UInt(bitPattern: pointer)) }
        prepared.increment()
      }
      return code
    }
    library.statements.execution.finalize = { statement in
      if let statement,
        preparedStatements.withLock({ $0.remove(UInt(bitPattern: statement)) != nil })
      {
        finalized.increment()
      }
      return base.statements.execution.finalize(statement)
    }

    try await withTestDatabaseFile("pool") { file in
      var configuration = SQLiteConfiguration.default
      configuration.readerCount = 1
      configuration.maximumCachedStatements = 0
      configuration.library = library
      let pool = try file.pool(configuration: configuration)
      try await pool.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT)")
      try await pool.execute(sql: "INSERT INTO items VALUES (1, 'One')")

      for _ in 0..<2 {
        #expect(
          try await pool.read {
            try $0.fetchAll(#sql("SELECT title FROM items ORDER BY id", as: String.self))
          } == ["One"]
        )
        #expect(
          try await pool.write {
            try $0.fetchAll(#sql("SELECT title FROM items ORDER BY id", as: String.self))
          } == ["One"]
        )
      }
      #expect(prepared.value == 4)
      #expect(finalized.value == prepared.value)
    }
  }

  @Test
  func anObservationOnAPoolSeesConcurrentWrites() async throws {
    try await withPool(readerCount: 2) { pool in
      let observedCounts = TestRecorder<Int>()
      let observedErrors = TestRecorder<String>()
      let observation = OrbitValueObservation<Int>
        .tracking { transaction in
          try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self)) ?? 0
        }
      let subscription = try observation.subscribe(
        to: pool,
        onError: { observedErrors.append(String(describing: $0)) },
        onChange: { observedCounts.append($0.value) }
      )
      defer { subscription.cancel() }
      try await observedCounts.waitForCount(1)
      #expect(observedCounts.values == [0])

      try await withThrowingTaskGroup(of: Void.self) { group in
        for id in 1...24 {
          group.addTask {
            try await pool.write { transaction in
              try transaction.execute(Item.insert { Item(id: id, title: "item \(id)") })
            }
          }
        }
        try await group.waitForAll()
      }

      // Refetches may combine several commits, but the last published value must be current.
      try await waitUntil { observedCounts.last == 24 }
      #expect(try await pool.rowCount(of: "items") == 24)
      #expect(observedCounts.values.dropFirst().allSatisfy { $0 > 0 && $0 <= 24 })
      #expect(observedErrors.values.isEmpty)
    }
  }

  @Test
  func poolReadersRefuseRawSQLWrites() async throws {
    try await withPool { pool throws in
      #expect(try await pool.pragma("query_only", as: Bool.self) == true)

      await #expect(throws: SQLiteError.self) {
        try await pool.read { transaction in
          try transaction.fetchAll(
            #sql("INSERT INTO items (title) VALUES ('nope') RETURNING id", as: Int.self)
          )
        }
      }
    }
  }

  @Test
  func aFailedPooledReadStillGivesItsReaderBack() async throws {
    try await withPool(readerCount: 1) { pool throws in
      for _ in 0..<5 {
        await #expect(throws: TestError()) {
          try await pool.read { _ in throw TestError() }
        }
      }

      // The one reader in the pool survived five failures.
      #expect(try await pool.rowCount(of: "items") == 0)
    }
  }

  @Test
  func readsRunAlongsideOneAnother() async throws {
    try await withPool(readerCount: 2) { pool in
      let gate = TestGate()

      let reads = (0..<2).map { _ in Task { try await pool.read { _ in try gate.enter() } } }
      // Both reads are inside the database at once; a serialized pool would never get here.
      try await gate.waitUntilEntered(2)
      gate.open()
      for read in reads { try await read.value }
    }
  }

  @Test
  func readsIssuedDuringAWriteWaitForItToCommit() async throws {
    try await withPool { pool in
      let gate = TestGate()

      let write = Task {
        try await pool.write { transaction in
          try transaction.execute(Item.insert { Item(id: 1, title: "in flight") })
          try gate.enter()
        }
      }
      try await gate.waitUntilEntered()

      let read = Task { try await pool.read { try $0.fetchAll(Item.all).count } }
      // The read is queued behind the write, so it cannot have run yet.
      await Task.yield()
      gate.open()
      try await write.value

      // And when it does run, it sees what the write committed.
      #expect(try await read.value == 1)
    }
  }

  @Test
  func aWriteWaitsForTheReadsInFlight() async throws {
    try await withPool { pool in
      let gate = TestGate()
      let wrote = Lock(false)

      let read = Task { try await pool.read { _ in try gate.enter() } }
      try await gate.waitUntilEntered()

      let write = Task {
        try await pool.write { transaction in
          wrote.withLock { $0 = true }
          try transaction.execute(Item.insert { Item(id: 1, title: "after read") })
        }
      }
      for _ in 0..<100 { await Task.yield() }
      #expect(!wrote.withLock { $0 })

      gate.open()
      try await read.value
      try await write.value
      #expect(wrote.withLock { $0 })
    }
  }

  @Test
  func aQueuedWriterRunsBeforeLaterReadersUnderReadPressure() async throws {
    try await withPool(readerCount: 2) { pool in
      let gate = TestGate()

      let blockingReads = (0..<2)
        .map { _ in Task { try await pool.read { _ in try gate.enter() } } }
      try await gate.waitUntilEntered(2)

      let writerRequested = TestCounter()
      let writer = Task {
        writerRequested.increment()
        try await pool.write { transaction in
          try transaction.execute(Item.insert { Item(id: 1, title: "writer") })
        }
      }
      try await writerRequested.waitForCount(1)
      for _ in 0..<100 { await Task.yield() }

      // Keep read pressure behind the writer. Every one of these must observe its commit;
      // granting any of them first would allow a steady read stream to starve the writer
      // indefinitely.
      let trailingRequested = TestCounter()
      let trailingReads = (0..<32)
        .map { _ in
          Task {
            trailingRequested.increment()
            return try await pool.read { try $0.fetchAll(Item.all).count }
          }
        }
      try await trailingRequested.waitForCount(trailingReads.count)
      for _ in 0..<100 { await Task.yield() }

      gate.open()
      for read in blockingReads { try await read.value }
      _ = try await writer.value
      for read in trailingReads {
        #expect(try await read.value == 1)
      }
    }
  }

  @Test
  func cancellingAQueuedWriteLetsTheRequestsBehindItRun() async throws {
    try await withPool { pool in
      let gate = TestGate()

      let read = Task { try await pool.read { _ in try gate.enter() } }
      try await gate.waitUntilEntered()

      let write = Task {
        try await pool.write { transaction in
          try transaction.execute(Item.insert { Item(id: 1, title: "never") })
        }
      }
      let trailingRead = Task { try await pool.read { try $0.fetchAll(Item.all).count } }
      for _ in 0..<100 { await Task.yield() }
      write.cancel()
      await #expect(throws: CancellationError.self) {
        try await write.value
      }

      // The trailing read was queued behind the write and is released by its cancellation,
      // rather than waiting on a write that will never run.
      gate.open()
      try await read.value
      #expect(try await trailingRead.value == 0)
    }
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }
#endif
