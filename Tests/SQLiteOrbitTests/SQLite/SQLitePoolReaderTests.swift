#if BuiltInSQLite && !os(WASI)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  // A pool opens its readers as reads need them, up to its reader count, and closes them again
  // when it releases memory.
  @Suite(.timeLimit(.minutes(1)))
  struct SQLitePoolReaderTests {
    // MARK: - Opening on demand

    @Test
    func readersOpenAsReadsNeedThemUpToTheReaderCount() async throws {
      try await withConnectionPool(readerCount: 3) { pool in
        try await pool.withWriteConnection { try $0.execute("INSERT INTO items VALUES (1)") }
        #expect(pool.readerCounts == (0, 0))
        #expect(try await pool.withReadConnection(countItems) == 1)
        #expect(try await pool.withReadConnection(countItems) == 1)
        #expect(pool.readerCounts == (1, 1))

        let gate = TestGate()
        let held = try await holdReads(3, on: pool, at: gate)
        #expect(pool.readerCounts == (3, 0))

        // A fourth read waits for one of those rather than opening a fourth reader.
        let waiting = Task { try await pool.withReadConnection { _ in try gate.enter() } }
        try await waitUntil { pool.waitingAccessCount == 1 }
        #expect(pool.readerCounts == (3, 0))

        gate.open()
        for task in held + [waiting] { try await task.value }
        #expect(pool.readerCounts == (3, 3))
      }
    }

    @Test
    func manyConcurrentReadsNeverOpenMoreThanTheReaderCount() async throws {
      try await withConnectionPool(readerCount: 2) { pool in
        let overlap = OverlapTracker()
        _ = try await concurrently(16) { _ in
          try await pool.withReadConnection { connection in
            try overlap.track { try countItems(connection) }
          }
        }
        _ = try await concurrentlyOnThreads(8) { _ in
          try pool.withReadConnectionBlocking { _ in overlap.track {} }
        }
        #expect(overlap.peak <= 2)
        let counts = pool.readerCounts
        #expect(counts.open <= 2)
        #expect(counts.open == counts.idle)
      }
    }

    @Test
    func readersOpenOffTheCooperativePool() async throws {
      // More readers opening at once than the cooperative pool has threads. Opening on the
      // awaiting task's thread would leave none to notice they had all started.
      let count = ProcessInfo.processInfo.activeProcessorCount + 4
      let opening = TestGate()
      let setup = SQLiteSetup { _ in try opening.enter() }
      try await withConnectionPool(readerCount: count, readerSetups: [setup]) { pool in
        let reads = (0..<count).map { _ in Task { try await pool.withReadConnection(countItems) } }
        try await opening.waitUntilEntered(count)
        #expect(pool.readerCounts == (count, 0))
        opening.open()
        for read in reads { #expect(try await read.value == 0) }
        #expect(pool.readerCounts == (count, count))
      }
    }

    // MARK: - Failing to open

    @Test(arguments: [false, true])
    func aReaderThatFailsToOpenFailsOnlyTheReadThatNeededIt(blocking: Bool) async throws {
      let failing = Lock(true)
      let setup = SQLiteSetup { _ in
        if failing.withLock({ $0 }) { throw TestError("reader setup") }
      }
      try await withConnectionPool(readerCount: 1, readerSetups: [setup]) { pool in
        await #expect(throws: TestError("reader setup")) {
          try await read(pool, blocking: blocking) { _ in }
        }
        // The slot it was granted went back, writes are unaffected, and the next read tries again.
        #expect(pool.readerCounts == (0, 0))
        try await pool.withWriteConnection { try $0.execute("INSERT INTO items VALUES (1)") }
        failing.withLock { $0 = false }
        #expect(try await read(pool, blocking: blocking, countItems) == 1)
        #expect(pool.readerCounts == (1, 1))
      }
    }

    @Test
    func aFailedOpenLetsTheReadsWaitingBehindItTryAgain() async throws {
      // The first reader opens; every reader after it fails until the test says otherwise.
      let opened = TestCounter()
      let failing = Lock(true)
      let setup = SQLiteSetup { _ in
        if opened.increment() > 1, failing.withLock({ $0 }) { throw TestError("reader setup") }
      }
      try await withConnectionPool(readerCount: 2, readerSetups: [setup]) { pool in
        let gate = TestGate()
        let held = try await holdReads(1, on: pool, at: gate)

        // With one reader held and one slot left, every read behind it either fails to open the
        // second reader or gets the slot back, and none of them is left waiting for good.
        let outcomes = try await concurrently(6) { _ -> Bool in
          do {
            try await pool.withReadConnection { _ in }
            return true
          } catch is TestError {
            return false
          }
        }
        #expect(outcomes.contains(false))
        #expect(pool.readerCounts == (1, 0))

        gate.open()
        for task in held { try await task.value }
        failing.withLock { $0 = false }
        _ = try await concurrently(4) { _ in try await pool.withReadConnection(countItems) }
        #expect(pool.readerCounts.open <= 2)
      }
    }

    // MARK: - Cancellation and fairness

    @Test
    func cancelledReadsRacingForSlotsLeakNothing() async throws {
      try await withConnectionPool(readerCount: 2) { pool in
        for _ in 0..<20 {
          let tasks = (0..<6).map { _ in Task { try await pool.withReadConnection { _ in } } }
          for task in tasks { task.cancel() }
          for task in tasks { _ = await task.result }
          let counts = pool.readerCounts
          #expect(counts.open == counts.idle)
          #expect(counts.open <= 2)
        }
        #expect(pool.waitingAccessCount == 0)
      }
    }

    @Test
    func aReadQueuedBehindABarrierWriteDoesNotOpenAReaderToJumpIt() async throws {
      try await withConnectionPool(readerCount: 2) { pool in
        let gate = TestGate()
        let held = try await holdReads(1, on: pool, at: gate)

        // A slot is free, but the write is a fairness boundary for the read behind it.
        let write = Task {
          try await pool.withWriteConnection { try $0.execute("INSERT INTO items VALUES (1)") }
        }
        try await waitUntil { pool.waitingAccessCount == 1 }
        let read = Task { try await pool.withReadConnection(countItems) }
        try await waitUntil { pool.waitingAccessCount == 2 }
        #expect(pool.readerCounts == (1, 0))

        gate.open()
        for task in held { try await task.value }
        try await write.value
        #expect(try await read.value == 1)
      }
    }

    // MARK: - Releasing memory

    @Test(arguments: [false, true])
    func releasingMemoryClosesIdleReadersNowAndBusyOnesWhenTheirReadsEnd(
      blocking: Bool
    ) async throws {
      try await withConnectionPool(readerCount: 2) { pool in
        let gate = TestGate()
        let warm = try await holdReads(2, on: pool, at: gate)
        gate.open()
        for task in warm { try await task.value }
        #expect(pool.readerCounts == (2, 2))

        let busyGate = TestGate()
        let busy = Task {
          try await read(pool, blocking: blocking) { connection in
            try busyGate.enter()
            return try countItems(connection)
          }
        }
        try await busyGate.waitUntilEntered()
        #expect(pool.readerCounts == (2, 1))

        // The release closes the idle reader without waiting for the read in progress.
        await pool.releaseMemory()
        #expect(pool.readerCounts == (1, 0))
        busyGate.open()
        #expect(try await busy.value == 0)
        #expect(pool.readerCounts == (0, 0))

        #expect(try await pool.withReadConnection(countItems) == 0)
        #expect(pool.readerCounts == (1, 1))
      }
    }

    @Test
    func aReaderStillOpeningWhenMemoryIsReleasedServesItsReadAndThenCloses() async throws {
      let opening = TestGate()
      let opened = TestCounter()
      let setup = SQLiteSetup { _ in
        if opened.increment() == 1 { try opening.enter() }
      }
      try await withConnectionPool(readerCount: 1, readerSetups: [setup]) { pool in
        let read = Task { try await pool.withReadConnection(countItems) }
        try await opening.waitUntilEntered()
        #expect(pool.readerCounts == (1, 0))
        await pool.releaseMemory()
        opening.open()
        #expect(try await read.value == 0)
        #expect(pool.readerCounts == (0, 0))
      }
    }

    @Test(arguments: [false, true])
    func releasingMemoryEmptiesTheWritersStatementCaches(suspended: Bool) async throws {
      try await withConnectionPool(readerCount: 1, writerCount: 2) { pool in
        let idleCount: @Sendable (borrowing SQLiteWriteConnection) -> Int = {
          $0.handle.pointee.statements.idleStatementCount
        }
        for _ in 0..<4 {
          try await pool.withConcurrentWriteConnection { connection in
            try connection.execute("INSERT INTO items VALUES (NULL)")
            _ = try countItems(connection)
          }
        }
        #expect(try await pool.withWriteConnection(idleCount) > 0)

        if suspended { pool.suspend() }
        await pool.releaseMemory()
        if suspended { pool.resume() }
        #expect(try await pool.withWriteConnection(idleCount) == 0)
        #expect(try await pool.withConcurrentWriteConnection(idleCount) == 0)
        #expect(try await pool.withReadConnection(countItems) == 4)
      }
    }

    @Test
    func releasingMemoryWaitsForAWriterInUseWithoutHoldingUpReads() async throws {
      try await withConnectionPool(readerCount: 1) { pool in
        let gate = TestGate()
        let write = Task {
          try await pool.withConcurrentWriteConnection { connection in
            _ = try countItems(connection)
            try gate.enter()
          }
        }
        try await gate.waitUntilEntered()
        let released = TestCounter()
        let release = Task {
          await pool.releaseMemory()
          released.increment()
        }
        // Reads go on while the release waits for the writer.
        for _ in 0..<3 { _ = try await pool.withReadConnection { _ in } }
        #expect(released.value == 0)
        gate.open()
        try await write.value
        await release.value
        #expect(released.value == 1)
      }
    }

    // MARK: - IPC

    @Test
    func anIPCDatabaseReleasesThroughAPoolWriter() async throws {
      try await withTestDatabaseFile("ipc-release") { file in
        let pool = try file.pool(readerCount: 2)
        let database = OrbitIPCDatabase(
          writer: pool,
          identifier: .unique(),
          transport: InMemoryIPCTransport(network: InMemoryIPCTransport.Network())
        )
        _ = try await database.read { try $0.fetchOne("SELECT 1") { $0[0].integerValue } }
        #expect(pool.pool.readerCounts == (1, 1))
        await database.releaseMemory()
        #expect(pool.pool.readerCounts == (0, 0))
      }
    }

    @Test
    func anIPCDatabaseLeavesAWriterThatCannotReleaseAlone() async throws {
      let database = OrbitIPCDatabase(
        writer: AnnouncingTestDatabase(try SQLiteQueue(path: .memory)),
        identifier: .unique(),
        transport: InMemoryIPCTransport(network: InMemoryIPCTransport.Network())
      )
      try await database.write { try $0.execute("CREATE TABLE items (id INTEGER)") }
      await database.releaseMemory()
      let count = try await database.read { transaction in
        try transaction.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
      }
      #expect(count == 0)
    }
  }

  extension SQLiteConnectionPool {
    fileprivate var readerCounts: (open: Int, idle: Int) { scheduler.readerCounts }
    fileprivate var waitingAccessCount: Int { scheduler.waitingAccessCount }
  }

  @Sendable
  private func countItems(_ connection: borrowing SQLiteReadConnection) throws -> Int64? {
    try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue } ?? nil
  }

  @Sendable
  private func countItems(_ connection: borrowing SQLiteWriteConnection) throws -> Int64? {
    try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue } ?? nil
  }

  /// Starts `count` reads that each hold a reader until `gate` opens, and waits until they all do.
  private func holdReads(
    _ count: Int,
    on pool: SQLiteConnectionPool,
    at gate: TestGate
  ) async throws -> [Task<Void, any Error>] {
    let tasks = (0..<count)
      .map { _ in
        Task { try await pool.withReadConnection { _ in try gate.enter() } }
      }
    try await gate.waitUntilEntered(count)
    return tasks
  }

  private func read<Result: Sendable>(
    _ pool: SQLiteConnectionPool,
    blocking: Bool,
    _ body: @escaping @Sendable (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    if blocking {
      try await withDeadline { try pool.withReadConnectionBlocking(body) }
    } else {
      try await pool.withReadConnection(body)
    }
  }

  private func withConnectionPool(
    readerCount: Int,
    writerCount: Int = 1,
    readerSetups: [SQLiteSetup] = [],
    _ body: (SQLiteConnectionPool) async throws -> Void
  ) async throws {
    try await withTestDatabaseFile("lazy-readers") { file in
      var writerConfiguration = SQLiteConfiguration.default
      #if Turso
        writerConfiguration.journalMode = .mvcc
      #else
        writerConfiguration.journalMode = .wal
      #endif
      let pool = try SQLiteConnectionPool(
        path: file.path,
        readerConfiguration: .default,
        writerConfiguration: writerConfiguration,
        readerCount: readerCount,
        writerCount: writerCount,
        readerSetups: readerSetups,
        writerSetups: [.script("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY)")]
      )
      try await body(pool)
    }
  }
#endif
