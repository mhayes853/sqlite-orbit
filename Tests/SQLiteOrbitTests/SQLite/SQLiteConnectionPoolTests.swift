#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  private func nativePoolRegion(_ precise: OrbitDatabaseRegion) -> OrbitDatabaseRegion {
    #if Turso
      .fullDatabase
    #else
      precise
    #endif
  }

  @Suite(.timeLimit(.minutes(1)))
  struct SQLiteConnectionPoolTests {
    @Test
    func callersComposeLoansAndChooseWhichTransactionsToObserve() async throws {
      try await withPublicConnectionPool { pool in
        let recorder = OrbitDatabaseRegionRecorder()
        try await pool.withWriteConnection { connection in
          try connection.transaction(observer: recorder) { transaction in
            try transaction.execute("INSERT INTO items VALUES (41)")
          }
        }
        let items = nativePoolRegion(OrbitDatabaseRegion(table: "items"))
        #expect(recorder.changedRegion == items)
        #expect(recorder.committedRegion == items)

        // The pool owns no registration: another loan only observes when its caller asks for it.
        try await pool.withWriteConnection { connection in
          try connection.execute("INSERT INTO lists VALUES (1)")
        }
        #expect(recorder.changedRegion == items)
        #expect(recorder.committedRegion == items)

        let ids = try await pool.withReadConnection { connection in
          try connection.transaction { transaction in
            try transaction.fetchAll("SELECT id FROM items") { $0[0].integerValue ?? 0 }
          }
        }
        #expect(ids == [41])
        let readerSetup = try await pool.withReadConnection { $0.configuration.setupSQL }
        let writerSetup = try await pool.withWriteConnection { $0.configuration.setupSQL }
        #expect(readerSetup == ["PRAGMA cache_size = 101"])
        #expect(writerSetup.contains("PRAGMA cache_size = 202"))
        #expect(!writerSetup.contains(poolItemsSchema))

        let blockingIDs = try await withDeadline {
          try pool.withReadConnectionBlocking { connection in
            try connection.transaction { transaction in
              try transaction.fetchAll("SELECT id FROM items") { $0[0].integerValue ?? 0 }
            }
          }
        }
        #expect(blockingIDs == ids)
        #expect(pool.captureActiveWriters() == nil)
      }
    }

    @Test(arguments: [false, true])
    func failedLoansRollBackTheirTransactionsAndRetainEarlierStatementCommits(blocking: Bool)
      async throws
    {
      try await withPublicConnectionPool { pool in
        let recorder = OrbitDatabaseRegionRecorder()
        let body: @Sendable (borrowing SQLiteWriteConnection) throws -> Void = { connection in
          try connection.withObservation(recorder) {
            try connection.execute("INSERT INTO items VALUES (1)")
            do {
              try connection.transaction { transaction in
                try transaction.execute("INSERT INTO items VALUES (2)")
                throw PoolLoanFailure()
              }
              Issue.record("The transaction did not report its failure")
            } catch {
              #expect(error is PoolLoanFailure)
            }
            try connection.execute("INSERT INTO lists VALUES (1)")
            throw PoolLoanFailure()
          }
        }
        do {
          try await runPublicWriteLoan(pool, blocking: blocking, body)
          Issue.record("The loan did not report its failure")
        } catch {
          #expect(error is PoolLoanFailure)
        }

        let committed = nativePoolRegion(
          OrbitDatabaseRegion(table: "items").union(OrbitDatabaseRegion(table: "lists"))
        )
        #expect(recorder.committedRegion == committed)
        #expect(recorder.hasCommitted)
        #expect(pool.captureActiveWriters() == nil)
        // A new loan can begin after the failure; the aborted row is absent and earlier work stays.
        try await runPublicWriteLoan(pool, blocking: blocking) { connection in
          try connection.transaction { transaction in
            try transaction.execute("INSERT INTO items VALUES (3)")
          }
        }
        let ids = try await pool.withReadConnection { connection in
          try connection.fetchAll("SELECT id FROM items ORDER BY id") { $0[0].integerValue ?? 0 }
        }
        #expect(ids == [1, 3])
      }
    }

    @Test
    func readerLoansDoNotBecomeActiveWriters() async throws {
      try await withPublicConnectionPool { pool in
        #expect(pool.captureActiveWriters() == nil)
        let gate = TestGate()
        defer { gate.open() }
        let read = Task {
          try await pool.withReadConnection { connection in
            let count = try connection.fetchOne("SELECT count(*) FROM items") {
              $0[0].integerValue ?? 0
            }
            try gate.enter()
            return count
          }
        }
        defer { read.cancel() }
        try await gate.waitUntilEntered()
        #expect(pool.captureActiveWriters() == nil)
        gate.open()
        #expect(try await read.value == 0)
      }
    }

    @Test(arguments: [false, true], [false, true])
    func capturedWritersFinishWithTheirLoanBodiesAndExcludeLaterLoans(
      firstBlocking: Bool,
      laterBlocking: Bool
    ) async throws {
      try await withPublicConnectionPool(writerCount: 2) { pool in
        let firstGate = TestGate()
        let laterGate = TestGate()
        defer {
          firstGate.open()
          laterGate.open()
        }
        let firstBodyFinished = TestCounter()
        let observer = PoolCommitCapture(pool: pool)
        let firstBody: @Sendable (borrowing SQLiteWriteConnection) throws -> Void = { connection in
          try connection.transaction(observer: observer) { transaction in
            try transaction.execute("INSERT INTO items VALUES (1)")
          }
          // The SQL transaction and its commit callback finished, but the borrowing body has not.
          try firstGate.enter()
          firstBodyFinished.increment()
        }
        let first = Task {
          try await runPublicConcurrentWriteLoan(pool, blocking: firstBlocking, firstBody)
        }
        defer { first.cancel() }
        try await firstGate.waitUntilEntered()
        let capturedCommit = try #require(observer.commits.last)
        let original = try #require(capturedCommit.barrier)
        #expect(capturedCommit.region == nativePoolRegion(OrbitDatabaseRegion(table: "items")))
        #expect(original.hasActiveWriters)
        #expect(firstBodyFinished.value == 0)

        let later = Task {
          try await runPublicConcurrentWriteLoan(pool, blocking: laterBlocking) { connection in
            _ = try connection.fetchOne("SELECT 1") { $0[0].integerValue ?? 0 }
            try laterGate.enter()
          }
        }
        defer { later.cancel() }
        try await laterGate.waitUntilEntered()
        let both = try #require(pool.captureActiveWriters())
        #expect(both.hasActiveWriters)
        let originalFinished = TestCounter()
        let wait = Task {
          await original.wait()
          originalFinished.increment()
        }
        defer { wait.cancel() }
        #expect(original.hasActiveWriters)
        #expect(originalFinished.value == 0)

        firstGate.open()
        try await first.value
        try await originalFinished.waitForCount(1)
        await wait.value
        #expect(firstBodyFinished.value == 1)
        #expect(!original.hasActiveWriters)
        // The later loan is still held, and belongs only to the newer snapshot.
        #expect(!laterGate.isOpen)
        #expect(both.hasActiveWriters)
        #expect(pool.captureActiveWriters() != nil)

        laterGate.open()
        try await later.value
        await both.wait()
        #expect(!both.hasActiveWriters)
        #expect(pool.captureActiveWriters() == nil)
      }
    }

    @Test(arguments: [false, true])
    func suspensionRefusesEveryHeldWriterAndResumeRestoresBothConnections(blocking: Bool)
      async throws
    {
      try await withPublicConnectionPool(writerCount: 2) { pool in
        let suspendedGate = TestGate()
        let resumedGate = TestGate()
        defer {
          suspendedGate.open()
          resumedGate.open()
        }
        let suspendedLoans = (1...2)
          .map { id in
            Task {
              try await runPublicConcurrentWriteLoan(pool, blocking: blocking) { connection in
                try suspendedGate.enter()
                try connection.execute("INSERT INTO items VALUES (\(id))")
              }
            }
          }
        defer { for loan in suspendedLoans { loan.cancel() } }
        try await suspendedGate.waitUntilEntered(2)
        pool.suspend()
        #expect(pool.isSuspended)
        suspendedGate.open()
        for loan in suspendedLoans {
          await #expect(throws: OrbitDatabaseSuspendedError.self) { try await loan.value }
        }
        let countWhileSuspended = try await pool.withReadConnection { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue ?? 0 }
        }
        #expect(countWhileSuspended == 0)
        #expect(pool.captureActiveWriters() == nil)

        pool.resume()
        #expect(!pool.isSuspended)
        let resumedLoans = (1...2)
          .map { id in
            Task {
              try await runPublicConcurrentWriteLoan(pool, blocking: blocking) { connection in
                // Holding both loans ensures that each writable connection is exercised after resume.
                try resumedGate.enter()
                try connection.execute("INSERT INTO items VALUES (\(id))")
              }
            }
          }
        defer { for loan in resumedLoans { loan.cancel() } }
        try await resumedGate.waitUntilEntered(2)
        resumedGate.open()
        for loan in resumedLoans { try await loan.value }
        let ids = try await pool.withReadConnection { connection in
          try connection.fetchAll("SELECT id FROM items ORDER BY id") { $0[0].integerValue ?? 0 }
        }
        #expect(ids == [1, 2])
      }
    }
  }

  private let poolItemsSchema = "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY)"
  private let poolListsSchema = "CREATE TABLE IF NOT EXISTS lists (id INTEGER PRIMARY KEY)"

  private func withPublicConnectionPool(
    writerCount: Int = 1,
    _ body: (SQLiteConnectionPool) async throws -> Void
  ) async throws {
    try await withTemporaryDirectory("low-pool") { directory in
      var readerConfiguration = SQLiteConfiguration.default
      readerConfiguration.readerCount = 2
      readerConfiguration.setupSQL = ["PRAGMA cache_size = 101"]
      var writerConfiguration = SQLiteConfiguration.default
      writerConfiguration.setupSQL = ["PRAGMA cache_size = 202"]
      #if Turso
        writerConfiguration.setupSQL.insert("PRAGMA journal_mode = MVCC", at: 0)
        let writerSetupSQL = [poolItemsSchema, poolListsSchema]
      #else
        let writerSetupSQL = ["PRAGMA journal_mode = WAL", poolItemsSchema, poolListsSchema]
      #endif
      let pool = try SQLiteConnectionPool(
        path: OrbitDatabasePath(directory.appendingPathComponent("database.sqlite").path),
        readerConfiguration: readerConfiguration,
        writerConfiguration: writerConfiguration,
        writerCount: writerCount,
        readerSetupSQL: ["PRAGMA query_only = 1"],
        writerSetupSQL: writerSetupSQL
      )
      try await body(pool)
    }
  }

  private func runPublicWriteLoan(
    _ pool: SQLiteConnectionPool,
    blocking: Bool,
    _ body: @escaping @Sendable (borrowing SQLiteWriteConnection) throws -> Void
  ) async throws {
    if blocking {
      try await withDeadline { try pool.withWriteConnectionBlocking(body) }
    } else {
      try await pool.withWriteConnection(body)
    }
  }

  private func runPublicConcurrentWriteLoan(
    _ pool: SQLiteConnectionPool,
    blocking: Bool,
    _ body: @escaping @Sendable (borrowing SQLiteWriteConnection) throws -> Void
  ) async throws {
    if blocking {
      try await withDeadline { try pool.withConcurrentWriteConnectionBlocking(body) }
    } else {
      try await pool.withConcurrentWriteConnection(body)
    }
  }

  private struct PoolLoanFailure: Error {}

  private struct PoolCapturedCommit: Sendable {
    let region: OrbitDatabaseRegion
    let barrier: (any OrbitDatabaseWriterBarrier)?
  }

  private final class PoolCommitCapture: OrbitDatabaseTransactionObserver, Sendable {
    private let pool: SQLiteConnectionPool
    let commits = TestRecorder<PoolCapturedCommit>()

    init(pool: SQLiteConnectionPool) {
      self.pool = pool
    }

    func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
      commits.append(
        PoolCapturedCommit(region: commit.region, barrier: pool.captureActiveWriters())
      )
    }
  }
#endif
