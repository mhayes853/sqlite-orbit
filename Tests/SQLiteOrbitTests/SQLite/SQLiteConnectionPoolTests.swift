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
                try transaction.execute("INSERT INTO lists VALUES (1)")
                throw PoolLoanFailure()
              }
              Issue.record("The transaction did not report its failure")
            } catch {
              #expect(error is PoolLoanFailure)
            }
            throw PoolLoanFailure()
          }
        }
        do {
          try await runPublicWriteLoan(pool, blocking: blocking, body)
          Issue.record("The loan did not report its failure")
        } catch {
          #expect(error is PoolLoanFailure)
        }

        #expect(recorder.committedRegion == nativePoolRegion(OrbitDatabaseRegion(table: "items")))
        #expect(
          recorder.changedRegion
            == nativePoolRegion(
              OrbitDatabaseRegion(table: "items").union(OrbitDatabaseRegion(table: "lists"))
            )
        )
        #expect(recorder.hasCommitted)
        #expect(pool.captureActiveWriters() == nil)
        // A new loan can begin after the failure; the aborted row is absent and earlier work stays.
        try await runPublicWriteLoan(pool, blocking: blocking) { connection in
          try connection.transaction { transaction in
            try transaction.execute("INSERT INTO items VALUES (3)")
          }
        }
        let ids = try await pool.withReadConnection { connection in
          let lists = try connection.fetchOne("SELECT count(*) FROM lists") {
            $0[0].integerValue ?? 0
          }
          #expect(lists == 0)
          return try connection.fetchAll("SELECT id FROM items ORDER BY id") {
            $0[0].integerValue ?? 0
          }
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
        let observer = PoolCommitCapture(pool: pool)
        let firstBody: @Sendable (borrowing SQLiteWriteConnection) throws -> Void = { connection in
          try connection.transaction(observer: observer) { transaction in
            try transaction.execute("INSERT INTO items VALUES (1)")
          }
          // The SQL transaction and its commit callback finished, but the borrowing body has not.
          try firstGate.enter()
        }
        let first = Task {
          try await runPublicWriteLoan(pool, blocking: firstBlocking, concurrent: true, firstBody)
        }
        defer { first.cancel() }
        try await firstGate.waitUntilEntered()
        let capturedCommit = try #require(observer.commits.last)
        let original = try #require(capturedCommit.barrier)
        #expect(capturedCommit.region == nativePoolRegion(OrbitDatabaseRegion(table: "items")))
        #expect(original.hasActiveWriters)

        let later = Task {
          try await runPublicWriteLoan(pool, blocking: laterBlocking, concurrent: true) {
            connection in
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
        #expect(originalFinished.value == 0)

        firstGate.open()
        try await first.value
        try await originalFinished.waitForCount(1)
        await wait.value
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
        for suspended in [true, false] {
          if !suspended { pool.resume() }
          let gate = TestGate()
          defer { gate.open() }
          let loans = (1...2)
            .map { id in
              Task {
                try await runPublicWriteLoan(pool, blocking: blocking, concurrent: true) {
                  connection in
                  // Both loans stay held so each writable connection is exercised in each phase.
                  try gate.enter()
                  try connection.execute("INSERT INTO items VALUES (\(id))")
                }
              }
            }
          defer { for loan in loans { loan.cancel() } }
          try await gate.waitUntilEntered(2)
          if suspended { pool.suspend() }
          #expect(pool.isSuspended == suspended)
          gate.open()
          for loan in loans {
            if suspended {
              await #expect(throws: OrbitDatabaseSuspendedError.self) { try await loan.value }
            } else {
              try await loan.value
            }
          }
          let ids = try await pool.withReadConnection { connection in
            try connection.fetchAll("SELECT id FROM items ORDER BY id") { $0[0].integerValue ?? 0 }
          }
          #expect(ids == (suspended ? [] : [1, 2]))
          #expect(pool.captureActiveWriters() == nil)
        }
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
    concurrent: Bool = false,
    _ body: @escaping @Sendable (borrowing SQLiteWriteConnection) throws -> Void
  ) async throws {
    switch (blocking, concurrent) {
    case (false, false): try await pool.withWriteConnection(body)
    case (false, true): try await pool.withConcurrentWriteConnection(body)
    case (true, false): try await withDeadline { try pool.withWriteConnectionBlocking(body) }
    case (true, true):
      try await withDeadline { try pool.withConcurrentWriteConnectionBlocking(body) }
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
