#if BuiltInSQLite && !os(WASI)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  // A pool opens its readers as reads need them, up to its reader count, and closes them again
  // when it releases memory. These hold it to never opening more than that, to keeping a reader
  // it failed to open from costing anything, and to leaving every other access as it was.
  @Suite(.timeLimit(.minutes(1)))
  struct SQLitePoolReaderTests {
    // MARK: - Opening on demand

    @Test(arguments: [false, true])
    func noReaderOpensUntilAReadNeedsOne(blocking: Bool) async throws {
      try await withConnectionPool(readerCount: 3) { pool in
        #expect(pool.readerCounts == (0, 0))
        // A write needs no reader.
        try await pool.withWriteConnection { try $0.execute("INSERT INTO items VALUES (1)") }
        #expect(pool.readerCounts == (0, 0))

        let count = try await read(pool, blocking: blocking) { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
        #expect(count == 1)
        #expect(pool.readerCounts == (1, 1))

        // One read after another reuses the reader it opened.
        for _ in 0..<3 {
          _ = try await read(pool, blocking: blocking) { _ in }
        }
        #expect(pool.readerCounts == (1, 1))
      }
    }

    @Test
    func concurrentReadsOpenOneReaderEachUpToTheReaderCount() async throws {
      try await withConnectionPool(readerCount: 3) { pool in
        let gate = TestGate()
        let held = (0..<3)
          .map { _ in
            Task { try await pool.withReadConnection { _ in try gate.enter() } }
          }
        try await gate.waitUntilEntered(3)
        #expect(pool.readerCounts == (3, 0))

        // A fourth read waits for one of those rather than opening a fourth reader.
        let waiting = Task { try await pool.withReadConnection { _ in try gate.enter() } }
        try await waitUntil { pool.waitingAccessCount == 1 }
        #expect(pool.readerCounts == (3, 0))

        gate.open()
        for task in held { try await task.value }
        try await waiting.value
        #expect(pool.readerCounts == (3, 3))
      }
    }

    @Test
    func manyConcurrentReadsNeverOpenMoreThanTheReaderCount() async throws {
      try await withConnectionPool(readerCount: 2) { pool in
        let overlap = OverlapTracker()
        _ = try await concurrently(16) { _ in
          try await pool.withReadConnection { connection in
            try overlap.track {
              try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
            }
          }
        }
        _ = try await concurrentlyOnThreads(8) { _ in
          try pool.withReadConnectionBlocking { _ in overlap.track {} }
        }
        #expect(overlap.peak <= 2)
        #expect(pool.readerCounts.open <= 2)
        #expect(pool.readerCounts.open == pool.readerCounts.idle)
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
        // The slot it was granted went back.
        #expect(pool.readerCounts == (0, 0))

        // Writes are unaffected, and the next read tries again.
        try await pool.withWriteConnection { try $0.execute("INSERT INTO items VALUES (1)") }
        await #expect(throws: TestError("reader setup")) {
          try await read(pool, blocking: blocking) { _ in }
        }
        #expect(pool.readerCounts == (0, 0))

        failing.withLock { $0 = false }
        let count = try await read(pool, blocking: blocking) { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
        #expect(count == 1)
        #expect(pool.readerCounts == (1, 1))
      }
    }

    @Test
    func aFailedOpenLetsTheReadsWaitingBehindItTryAgain() async throws {
      // The first reader opens; every reader after it fails until the test says otherwise.
      let opened = Lock(0)
      let failing = Lock(true)
      let setup = SQLiteSetup { _ in
        let index = opened.withLock { opened in
          defer { opened += 1 }
          return opened
        }
        if index > 0, failing.withLock({ $0 }) { throw TestError("reader setup") }
      }
      try await withConnectionPool(readerCount: 2, readerSetups: [setup]) { pool in
        let gate = TestGate()
        let held = Task { try await pool.withReadConnection { _ in try gate.enter() } }
        try await gate.waitUntilEntered()

        // With one reader held and one slot left, every read behind it either fails to open the
        // second reader or waits, and none of them is left waiting for good.
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
        try await held.value
        #expect(pool.readerCounts == (1, 1))
        failing.withLock { $0 = false }
        try await pool.withWriteConnection { try $0.execute("INSERT INTO items VALUES (1)") }
        _ = try await concurrently(4) { _ in
          try await pool.withReadConnection { _ in try gate.enter() }
        }
        #expect(pool.readerCounts.open <= 2)
      }
    }

    // MARK: - Cancellation

    @Test
    func cancellingAReadWaitingForAReaderLeaksNothing() async throws {
      try await withConnectionPool(readerCount: 1) { pool in
        let gate = TestGate()
        let held = Task { try await pool.withReadConnection { _ in try gate.enter() } }
        try await gate.waitUntilEntered()

        let cancelled = Task { try await pool.withReadConnection { _ in } }
        try await waitUntil { pool.waitingAccessCount == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(pool.waitingAccessCount == 0)

        gate.open()
        try await held.value
        #expect(pool.readerCounts == (1, 1))
        _ = try await pool.withReadConnection { _ in }
        #expect(pool.readerCounts == (1, 1))
      }
    }

    @Test
    func cancelledReadsRacingForSlotsLeakNothing() async throws {
      try await withConnectionPool(readerCount: 2) { pool in
        for _ in 0..<20 {
          let tasks = (0..<6)
            .map { _ in
              Task { try await pool.withReadConnection { _ in } }
            }
          for task in tasks { task.cancel() }
          for task in tasks { _ = await task.result }
          let counts = pool.readerCounts
          #expect(counts.open == counts.idle)
          #expect(counts.open <= 2)
        }
        #expect(pool.waitingAccessCount == 0)
      }
    }

    // MARK: - Fairness

    @Test
    func aReadQueuedBehindABarrierWriteDoesNotOpenAReaderToJumpIt() async throws {
      try await withConnectionPool(readerCount: 2) { pool in
        let events = TestRecorder<String>()
        let gate = TestGate()
        let held = Task {
          try await pool.withReadConnection { _ in
            try gate.enter()
            events.append("first read")
          }
        }
        try await gate.waitUntilEntered()

        // A slot is free, but the write is a fairness boundary for the read behind it.
        let write = Task {
          try await pool.withWriteConnection { connection in
            try connection.execute("INSERT INTO items VALUES (1)")
            events.append("write")
          }
        }
        try await waitUntil { pool.waitingAccessCount == 1 }
        let read = Task {
          try await pool.withReadConnection { connection in
            events.append("second read")
            return try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
          }
        }
        try await waitUntil { pool.waitingAccessCount == 2 }
        #expect(pool.readerCounts == (1, 0))

        gate.open()
        try await held.value
        try await write.value
        #expect(try await read.value == 1)
        #expect(events.values == ["first read", "write", "second read"])
      }
    }

    // MARK: - Releasing memory

    @Test
    func releasingMemoryClosesIdleReadersAndReadsReopenThem() async throws {
      try await withConnectionPool(readerCount: 3) { pool in
        let gate = TestGate()
        let held = (0..<3)
          .map { _ in
            Task { try await pool.withReadConnection { _ in try gate.enter() } }
          }
        try await gate.waitUntilEntered(3)
        gate.open()
        for task in held { try await task.value }
        #expect(pool.readerCounts == (3, 3))

        await pool.releaseMemory()
        #expect(pool.readerCounts == (0, 0))

        let count = try await pool.withReadConnection { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
        #expect(count == 0)
        #expect(pool.readerCounts == (1, 1))
      }
    }

    @Test(arguments: [false, true])
    func aReaderInUseClosesWhenItsReadEnds(blocking: Bool) async throws {
      try await withConnectionPool(readerCount: 2) { pool in
        _ = try await pool.withReadConnection { _ in }
        let gate = TestGate()
        let busy: Task<Int64??, any Error>
        if blocking {
          busy = Task {
            try await withDeadline {
              try pool.withReadConnectionBlocking { connection in
                try gate.enter()
                return try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
              }
            }
          }
        } else {
          busy = Task {
            try await pool.withReadConnection { connection in
              try gate.enter()
              return try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
            }
          }
        }
        try await gate.waitUntilEntered()
        #expect(pool.readerCounts == (1, 0))

        // The release does not wait for the read in progress, which keeps working.
        await pool.releaseMemory()
        #expect(pool.readerCounts == (1, 0))
        gate.open()
        #expect(try await busy.value == 0)
        #expect(pool.readerCounts == (0, 0))

        _ = try await pool.withReadConnection { _ in }
        #expect(pool.readerCounts == (1, 1))
      }
    }

    @Test
    func aReaderStillOpeningWhenMemoryIsReleasedServesItsReadAndThenCloses() async throws {
      let opening = TestGate()
      let isFirst = Lock(true)
      let setup = SQLiteSetup { _ in
        if isFirst.withLock({ first in
          defer { first = false }
          return first
        }) {
          try opening.enter()
        }
      }
      try await withConnectionPool(readerCount: 1, readerSetups: [setup]) { pool in
        let read = Task {
          try await pool.withReadConnection { connection in
            try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
          }
        }
        try await opening.waitUntilEntered()
        #expect(pool.readerCounts == (1, 0))
        await pool.releaseMemory()
        opening.open()
        #expect(try await read.value == 0)
        #expect(pool.readerCounts == (0, 0))
      }
    }

    @Test(arguments: [false, true])
    func releasingMemoryEmptiesTheWritersStatementCache(suspended: Bool) async throws {
      try await withConnectionPool(readerCount: 1, writerCount: 2) { pool in
        let idleCount: @Sendable (borrowing SQLiteWriteConnection) -> Int = {
          $0.handle.pointee.statements.idleStatementCount
        }
        for _ in 0..<4 {
          try await pool.withConcurrentWriteConnection { connection in
            try connection.execute("INSERT INTO items VALUES (NULL)")
            _ = try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
          }
        }
        #expect(try await pool.withWriteConnection(idleCount) > 0)

        if suspended { pool.suspend() }
        await pool.releaseMemory()
        if suspended { pool.resume() }
        #expect(try await pool.withWriteConnection(idleCount) == 0)
        #expect(try await pool.withConcurrentWriteConnection(idleCount) == 0)

        try await pool.withWriteConnection { try $0.execute("INSERT INTO items VALUES (NULL)") }
        let count = try await pool.withReadConnection { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
        #expect(count == 5)
      }
    }

    @Test
    func releasingMemoryWaitsForAWriterInUseWithoutHoldingUpReads() async throws {
      try await withConnectionPool(readerCount: 1) { pool in
        let gate = TestGate()
        let write = Task {
          try await pool.withConcurrentWriteConnection { connection in
            _ = try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
            try gate.enter()
          }
        }
        try await gate.waitUntilEntered()
        let released = TestCounter()
        let release = Task {
          await pool.releaseMemory()
          _ = released.increment()
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

    @Test
    func aSQLitePoolReleasesThroughItsConnectionPool() async throws {
      try await withTestDatabaseFile("pool-release") { file in
        let pool = try file.pool(readerCount: 2)
        #expect(pool.readerCounts == (0, 0))
        _ = try await pool.read { try $0.fetchOne("SELECT 1") { $0[0].integerValue } }
        #expect(pool.readerCounts == (1, 1))
        let memoryReleasing: any OrbitMemoryReleasing = pool
        await memoryReleasing.releaseMemory()
        #expect(pool.readerCounts == (0, 0))
        _ = try await pool.read { try $0.fetchOne("SELECT 1") { $0[0].integerValue } }
        #expect(pool.readerCounts == (1, 1))
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
        #expect(pool.readerCounts == (1, 1))
        await database.releaseMemory()
        #expect(pool.readerCounts == (0, 0))
        _ = try await database.read { try $0.fetchOne("SELECT 1") { $0[0].integerValue } }
        #expect(pool.readerCounts == (1, 1))
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
