#if BuiltInSQLite
  import Foundation
  import StructuredQueries
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLitePoolSuspensionTests {
    @Test
    func suspendedPoolRefusesWritesAndKeepsReadingUntilResumed() async throws {
      try await withPooledDatabase(configuration: .default) { pool in
        try await createItems(in: pool)
        pool.suspend()
        #expect(pool.isSuspended)

        let refusal = OrbitDatabaseSuspendedError(databaseIdentifier: pool.defaultIdentifier)
        await #expect(throws: refusal) {
          try await pool.write { try $0.execute("INSERT INTO items DEFAULT VALUES") }
        }
        #expect(throws: OrbitDatabaseSuspendedError.self) {
          try pool.writeBlocking { try $0.execute("INSERT INTO items DEFAULT VALUES") }
        }
        await #expect(throws: OrbitDatabaseSuspendedError.self) {
          try await pool.writeWithoutTransaction {
            try $0.execute("INSERT INTO items DEFAULT VALUES")
          }
        }
        #expect(try await itemCount(in: pool) == 0)

        pool.resume()
        #expect(!pool.isSuspended)
        try await pool.write { try $0.execute("INSERT INTO items DEFAULT VALUES") }
        #expect(try await itemCount(in: pool) == 1)
      }
    }

    @Test
    func suspendedWriterStillReadsOutsideATransaction() async throws {
      // A launch that finds its database up to date only reads the applied migrations on the
      // writer, and should not fail for being suspended.
      try await withPooledDatabase(configuration: .default) { pool in
        try await createItems(in: pool)
        pool.suspend()

        let count = try await pool.writeWithoutTransaction { connection in
          try connection.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
        }

        #expect(count == 0)
      }
    }

    @Test
    func suspendedWriterRefusesRawConnectionStatements() async throws {
      try await withPooledDatabase(configuration: .default) { pool in
        try await createItems(in: pool)
        pool.suspend()

        let result = try await pool.writeWithoutTransaction { connection in
          let library = connection.sqlite
          var statement: OpaquePointer?
          let preparation = "INSERT INTO items DEFAULT VALUES"
            .withCString {
              library.statements.preparation.prepare(
                connection.sqliteConnection,
                $0,
                -1,
                0,
                &statement,
                nil
              )
            }
          #expect(preparation == SQLiteResultCode.ok.rawValue)
          defer { _ = library.statements.execution.finalize(statement) }
          return library.statements.execution.step(statement)
        }

        #expect(result == SQLiteResultCode.interrupt.rawValue)
        #expect(try await itemCount(in: pool) == 0)
      }
    }

    @Test
    func suspendingInterruptsTheRunningWriteAndRollsItBack() async throws {
      let steps = EndlessStepCounter()
      var configuration = SQLiteConfiguration.default
      configuration.library = steps.library
      try await withPooledDatabase(configuration: configuration) { pool in
        try await createItems(in: pool)
        let running = Task {
          try await pool.write { transaction in
            try transaction.execute("INSERT INTO items DEFAULT VALUES")
            _ = try transaction.fetchAll(endlessCount)
          }
        }
        try await waitUntil { steps.count > 0 }

        pool.suspend()

        // A suspension is not a cancellation, so it is reported as itself.
        await #expect(throws: OrbitDatabaseSuspendedError.self) { try await running.value }
        #expect(try await itemCount(in: pool) == 0)
        pool.resume()
        try await pool.write { try $0.execute("INSERT INTO items DEFAULT VALUES") }
        #expect(try await itemCount(in: pool) == 1)
      }
    }

    @Test
    func writeSuspendedBetweenStatementsDoesNotCommitEvenWhenItIgnoresTheRefusal() async throws {
      try await withPooledDatabase(configuration: .default) { pool in
        try await createItems(in: pool)
        let hasInserted = Lock(false)
        let refusal = Lock<(any Error)?>(nil)
        let running = Task {
          try await pool.write { transaction in
            try transaction.execute("INSERT INTO items DEFAULT VALUES")
            hasInserted.withLock { $0 = true }
            // Swift code between statements, which an interrupt cannot reach.
            while !pool.isSuspended { Thread.sleep(forTimeInterval: 0.001) }
            do {
              try transaction.execute("INSERT INTO items DEFAULT VALUES")
            } catch {
              refusal.withLock { $0 = error }
            }
          }
        }
        try await waitUntil { hasInserted.withLock { $0 } }

        pool.suspend()

        await #expect(throws: OrbitDatabaseSuspendedError.self) { try await running.value }
        let refused = try #require(refusal.withLock { $0 } as? SQLiteError)
        #expect(refused.isInterruption)
        #expect(try await itemCount(in: pool) == 0)
      }
    }

    @Test
    func failureOfItsOwnIsReportedAsItIsWhileSuspended() async throws {
      struct Failure: Error {}
      try await withPooledDatabase(configuration: .default) { pool in
        try await createItems(in: pool)

        await #expect(throws: Failure.self) {
          try await pool.write { transaction in
            pool.suspend()
            _ = try? transaction.execute("INSERT INTO items DEFAULT VALUES")
            throw Failure()
          }
        }
        #expect(try await itemCount(in: pool) == 0)
      }
    }

    @Test
    func suspendingOneDatabaseLeavesAnotherOnTheSameLibraryAlone() async throws {
      try await withPooledDatabase(configuration: .default) { suspended in
        try await withPooledDatabase(configuration: .default) { other in
          try await createItems(in: suspended)
          try await createItems(in: other)

          suspended.suspend()

          try await other.write { try $0.execute("INSERT INTO items DEFAULT VALUES") }
          #expect(try await itemCount(in: other) == 1)
        }
      }
    }

    @Test
    func ipcDatabaseSuspendsItsWriterAndAnnouncesNothingItRefused() async throws {
      try await withPooledDatabase(configuration: .default) { pool in
        try await createItems(in: pool)
        let delegate = AnnouncementCounter()
        let database = OrbitIPCDatabase(
          writer: pool,
          transport: InMemoryIPCTransport(),
          delegate: delegate
        )

        database.suspend()

        #expect(database.isSuspended)
        #expect(pool.isSuspended)
        await #expect(throws: OrbitDatabaseSuspendedError.self) {
          try await database.write { try $0.execute("INSERT INTO items DEFAULT VALUES") }
        }
        #expect(delegate.count == 0)

        database.resume()

        #expect(!pool.isSuspended)
        try await database.write { try $0.execute("INSERT INTO items DEFAULT VALUES") }
        #expect(delegate.count == 1)
      }
    }
  }

  private let endlessMarker = "RECURSIVE endless"

  private let endlessCount = #sql(
    """
    WITH RECURSIVE endless(x) AS (
      SELECT 1 UNION ALL SELECT x + 1 FROM endless WHERE x < 2000000000
    )
    SELECT count(*) FROM endless
    """,
    as: Int.self
  )

  private func createItems(in pool: SQLitePool) async throws {
    try await pool.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
  }

  private func itemCount(in pool: SQLitePool) async throws -> Int? {
    try await pool.read { transaction in
      try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
    }
  }

  private final class EndlessStepCounter: Sendable {
    private let steps = Lock(0)

    var count: Int { steps.withLock { $0 } }

    var library: SQLiteLibrary {
      let base = builtInTestLibrary
      var library = base
      library.statements.execution.step = { [self] statement in
        if let sql = base.statements.inspection.sql(statement),
          String(cString: sql).contains(endlessMarker)
        {
          steps.withLock { $0 += 1 }
        }
        return base.statements.execution.step(statement)
      }
      return library
    }
  }

  private final class AnnouncementCounter: OrbitIPCDatabase.Delegate {
    private let announcements = Lock(0)

    var count: Int { announcements.withLock { $0 } }

    func orbitIPCDatabase(_ database: OrbitIPCDatabase, willAnnounce message: OrbitIPCMessage) {
      announcements.withLock { $0 += 1 }
    }
  }
#endif
