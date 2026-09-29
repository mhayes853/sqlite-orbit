#if StructuredQueries
  import StructuredQueriesSQLite

  #if Turso
    import Dispatch
    import Foundation
    import Testing

    @testable import SQLiteOrbit

    @DatabaseCollation
    private func tursoTestCollation(_ lhs: String, _ rhs: String) -> CollationOrder {
      CollationOrder(lhs, rhs)
    }

    @Test
    func tursoRunsBasicQueueTransactions() async throws {
      #expect(SQLiteConfiguration.default.library.name == "Turso")
      #expect(SQLiteConfiguration.default.isTrustedSchemaEnabled)

      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute(
          #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
        )
        try transaction.execute(
          #sql("INSERT INTO notes (id, title) VALUES (1, 'hello')", as: Void.self)
        )
      }

      let titles = try await database.read { transaction in
        try transaction.fetchAll(#sql("SELECT title FROM notes", as: String.self))
      }
      #expect(titles == ["hello"])
    }

    @Test
    func tursoRunsAPoolConfinedToOneProcess() async throws {
      try await withTestDatabaseFile("turso") { file in
        let database = try file.tursoPool()
        try await database.write { transaction in
          try transaction.execute(
            #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
          )
          try transaction.execute(
            #sql("INSERT INTO notes (id, title) VALUES (1, 'pooled')", as: Void.self)
          )
        }
        let titles = try await database.read { transaction in
          try transaction.fetchAll(#sql("SELECT title FROM notes", as: String.self))
        }
        #expect(titles == ["pooled"])
      }
    }

    @Test
    func tursoPoolRunsInMVCCMode() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path)

        let mode = try await driver.readWithoutTransaction { connection in
          try connection.fetchOne(#sql("SELECT * FROM pragma_journal_mode", as: String.self))
        }

        #expect(mode?.lowercased() == "mvcc")
      }
    }

    @Test
    func tursoPoolSupportsWritesOutsideATransaction() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path)
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }

        try await driver.writeWithoutTransaction { connection in
          try connection.execute("INSERT INTO items (id) VALUES (1)")
          try connection.execute("INSERT INTO items (id) VALUES (2)")
        }

        let count = try await driver.readWithoutTransaction { connection in
          try connection.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
        }
        #expect(count == 2)
      }
    }

    @Test
    func tursoPoolRunsConcurrentWritesOnDistinctConnections() async throws {
      try await withTestDatabaseFile("turso") { file in
        let database = try TursoPool(path: file.path, writerCount: 2)
        try await database.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        let gate = TestGate()

        let writes = (1...2)
          .map { id in
            Task {
              try await database.concurrentWrite { transaction in
                try transaction.executeScript("INSERT INTO items (id) VALUES (\(id))")
                try gate.enter()
              }
            }
          }

        try await gate.waitUntilEntered(2)
        gate.open()
        for write in writes { try await write.value }

        let count = try await database.read { transaction in
          try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
        }
        #expect(count == 2)
      }
    }

    @Test
    func tursoPoolPublishesEachConcurrentCommitWithItsActiveWriterCohort() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path, writerCount: 2)
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        let observer = TransactionEventRecorder()
        let subscription = try driver.subscribe(transactionObserver: observer)
        let firstGate = TestGate()
        let secondGate = TestGate()

        let first = Task {
          try await driver.concurrentWrite { transaction in
            try transaction.execute("INSERT INTO items VALUES (1)")
            try firstGate.enter()
          }
        }
        let second = Task {
          try await driver.concurrentWrite { transaction in
            try transaction.execute("INSERT INTO items VALUES (2)")
            try secondGate.enter()
          }
        }
        try await firstGate.waitUntilEntered(1)
        try await secondGate.waitUntilEntered(1)

        firstGate.open()
        try await first.value
        let firstCommit = try #require(observer.commits.first)
        #expect(firstCommit.origin == .local)
        #expect(firstCommit.region.isFullDatabase)
        let barrier = try #require(firstCommit.activeWriterBarrier)
        #expect(barrier.hasActiveWriters)

        let barrierFinished = Lock(false)
        let wait = Task {
          await barrier.wait()
          barrierFinished.withLock { $0 = true }
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!barrierFinished.withLock { $0 })

        secondGate.open()
        try await second.value
        await wait.value
        #expect(barrierFinished.withLock { $0 })
        #expect(observer.commits.count == 2)
        _ = subscription
      }
    }

    @Test
    func coalescedObservationWaitsForTheConcurrentTursoWriterCohort() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path, writerCount: 2)
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        let fetchCount = Lock(0)
        let observation = OrbitValueObservation<Int>
          .tracking { transaction in
            fetchCount.withLock { $0 += 1 }
            return try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self)) ?? 0
          }
          .refetching(.coalesced)
        let recorder = TestRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: { Issue.record("Unexpected observation error: \($0)") },
          onChange: { recorder.append($0.value) }
        )
        try await recorder.waitForCount(1)
        let firstGate = TestGate()
        let secondGate = TestGate()

        let first = Task {
          try await driver.concurrentWrite { transaction in
            try transaction.execute("INSERT INTO items VALUES (1)")
            try firstGate.enter()
          }
        }
        let second = Task {
          try await driver.concurrentWrite { transaction in
            try transaction.execute("INSERT INTO items VALUES (2)")
            try secondGate.enter()
          }
        }
        try await firstGate.waitUntilEntered(1)
        try await secondGate.waitUntilEntered(1)

        firstGate.open()
        try await first.value
        for _ in 0..<100 { await Task.yield() }
        #expect(recorder.values == [0])

        secondGate.open()
        try await second.value
        try await recorder.waitForCount(2)
        #expect(recorder.values == [0, 2])
        #expect(fetchCount.withLock { $0 } == 2)
        _ = subscription
      }
    }

    @Test
    func tursoPoolDoesNotPublishFailedConcurrentWrites() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path, writerCount: 1)
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE discarded (id INTEGER)")
        }
        let observer = TransactionEventRecorder()
        let subscription = try driver.subscribe(transactionObserver: observer)

        await #expect(throws: TestError()) {
          try await driver.concurrentWrite { transaction in
            try transaction.execute("INSERT INTO discarded VALUES (1)")
            throw TestError()
          }
        }

        #expect(observer.commits.isEmpty)
        _ = subscription
      }
    }

    @Test
    func tursoPoolSurfacesAConcurrentWriteConflict() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path, writerCount: 2)
        try await driver.write { transaction in
          try transaction.executeScript(
            "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);"
              + " INSERT INTO counter VALUES (1, 0)"
          )
        }
        let gate = TestGate()

        let writes = (1...2)
          .map { value in
            Task { () -> SQLiteError? in
              do {
                try await driver.concurrentWrite { transaction in
                  _ = try transaction.fetchOne(
                    #sql("SELECT value FROM counter WHERE id = 1", as: Int.self)
                  )
                  try gate.enter()
                  try transaction.executeScript("UPDATE counter SET value = \(value) WHERE id = 1")
                }
                return nil
              } catch let error as SQLiteError {
                return error
              } catch {
                Issue.record("Unexpected conflict error: \(error)")
                return nil
              }
            }
          }

        try await gate.waitUntilEntered(2)
        gate.open()
        var errors: [SQLiteError] = []
        for write in writes {
          if let error = await write.value { errors.append(error) }
        }

        #expect(errors.count == 1)
        let conflict = try #require(errors.first)
        #expect(
          conflict.primaryCode == .busy
            || conflict.message?.localizedCaseInsensitiveContains("conflict") == true
        )
        // The connection whose transaction lost the conflict was rolled back and remains usable.
        try await driver.concurrentWrite { transaction in
          try transaction.execute("INSERT INTO counter VALUES (2, 3)")
        }
      }
    }

    @Test
    func tursoPoolRunsAReadAlongsideAConcurrentWrite() async throws {
      try await withTestDatabaseFile("turso") { file in
        var configuration = SQLiteConfiguration.turso
        configuration.readerCount = 1
        let driver = try TursoPool(path: file.path, configuration: configuration, writerCount: 1)
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        let gate = TestGate()

        let read = Task { try await driver.read { _ in try gate.enter() } }
        let write = Task {
          try await driver.concurrentWrite { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (1)")
            try gate.enter()
          }
        }

        try await gate.waitUntilEntered(2)
        gate.open()
        try await read.value
        try await write.value
      }
    }

    @Test
    func tursoPoolWriteIsABarrierForOrdinaryAccesses() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path, writerCount: 1)
        let gate = TestGate()
        let entryOrder = TestRecorder<String>()

        let read = Task { try await driver.read { _ in try gate.enter() } }
        try await gate.waitUntilEntered(1)
        let barrier = Task {
          try await driver.write { transaction in
            entryOrder.append("barrier")
            try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
          }
        }
        for _ in 0..<100 { await Task.yield() }
        let trailingWrite = Task {
          try await driver.concurrentWrite { _ in
            entryOrder.append("trailing write")
          }
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(entryOrder.values.isEmpty)

        gate.open()
        try await read.value
        try await barrier.value
        try await trailingWrite.value
        #expect(entryOrder.values == ["barrier", "trailing write"])
      }
    }

    @Test
    func cancellingAQueuedTursoConcurrentWriteReturnsTheCapacity() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path, writerCount: 1)
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        let gate = TestGate()

        let holding = Task { try await driver.concurrentWrite { _ in try gate.enter() } }
        try await gate.waitUntilEntered(1)
        let cancelled = Task {
          try await driver.concurrentWrite { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (1)")
          }
        }
        for _ in 0..<100 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        gate.open()
        try await holding.value
        try await driver.concurrentWrite { transaction in
          try transaction.execute("INSERT INTO items (id) VALUES (2)")
        }
      }
    }

    @Test
    func tursoPoolBlockingAccessesUseTheSameConnections() throws {
      try withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path, writerCount: 2)

        try driver.writeBlocking { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        try driver.writeWithoutTransactionBlocking { connection in
          try connection.execute("INSERT INTO items (id) VALUES (1)")
        }
        let count = try driver.readWithoutTransactionBlocking { connection in
          try connection.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
        }

        #expect(count == 1)
      }
    }

    @Test
    func tursoPoolBlockingWritesCanRunConcurrently() async throws {
      try await withTestDatabaseFile("turso") { file in
        let driver = try TursoPool(path: file.path, writerCount: 2)
        try driver.writeBlocking { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        let gate = TestGate()

        async let writes = concurrentlyOnThreads(2) { index in
          try driver.concurrentWriteBlocking { transaction in
            try transaction.executeScript("INSERT INTO items (id) VALUES (\(index + 1))")
            try gate.enter()
          }
        }

        try await gate.waitUntilEntered(2)
        gate.open()
        _ = try await writes

        let count = try driver.readBlocking { transaction in
          try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
        }
        #expect(count == 2)
      }
    }

    @Test(arguments: [OrbitDatabasePath.memory, .temporary, ":memory:", ""])
    func tursoPoolRejectsDatabasesPrivateToAConnection(path: OrbitDatabasePath) {
      #expect(throws: SQLitePoolUnavailableError.self) {
        _ = try TursoPool(path: path)
      }
    }

    @Test
    func tursoUsesWholeDatabaseRegionsWithoutAnAuthorizer() throws {
      let handle = try SQLiteHandle.open(
        path: .memory,
        flags: [.readWrite, .create, .memory, .noMutex],
        configuration: .turso
      )
      try handle.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")

      let read = try handle.statements.prepare("SELECT title FROM notes")
      defer { _ = handle.library.pointee.statements.execution.finalize(read.pointer) }
      #expect(read.readRegion.isFullDatabase)

      let write = try handle.statements.prepare("INSERT INTO notes (title) VALUES ('hello')")
      defer { _ = handle.library.pointee.statements.execution.finalize(write.pointer) }
      #expect(write.changedRegion.isFullDatabase)
      #expect(write.invalidatesStatementCache)
    }

    @Test
    func tursoRefusesWritesPassedThroughAReadTransaction() throws {
      let handle = try SQLiteHandle.open(
        path: .memory,
        flags: [.readWrite, .create, .memory, .noMutex],
        configuration: .turso
      )
      try handle.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY)")

      #expect(throws: SQLiteError.self) {
        try handle.read { transaction in
          try transaction.fetchAll(
            #sql("INSERT INTO notes DEFAULT VALUES RETURNING id", as: Int.self)
          )
        }
      }
    }

    @Test
    func tursoReportsFeaturesItCannotProvide() {
      var hardened = SQLiteConfiguration.turso
      hardened.isTrustedSchemaEnabled = false
      #expect(throws: SQLiteFeatureUnavailableError.self) {
        _ = try SQLiteQueue(path: .memory, configuration: hardened)
      }

      var withCollation = SQLiteConfiguration.turso
      withCollation.register(collation: $tursoTestCollation)
      #expect(throws: SQLiteFeatureUnavailableError.self) {
        _ = try SQLiteQueue(path: .memory, configuration: withCollation)
      }

      #if canImport(Darwin) || canImport(Glibc)
        #expect(throws: SQLiteFeatureUnavailableError.self) {
          _ = try OrbitIPCDatabase(path: "/tmp/turso-multiprocess.sqlite")
        }
      #endif
    }

    @Test
    func tursoRefusesToCheckForeignKeysRatherThanReportNoViolations() async throws {
      #expect(!SQLiteLibrary.turso.isForeignKeyCheckAvailable)
      let expected = SQLiteFeatureUnavailableError(libraryName: "Turso", feature: .foreignKeyCheck)
      #expect(expected.description == "Turso does not support SQLite's foreign key checks.")

      // Turso answers `PRAGMA foreign_key_check` with no rows, even for a row that refers to
      // nothing, which is what an empty result would wrongly vouch for.
      let driver = try SQLiteQueue(path: .memory)
      try await driver.writeWithoutTransaction { connection in
        connection.isForeignKeysEnabled = false
        try connection.executeScript(
          """
          CREATE TABLE lists (id INTEGER PRIMARY KEY);
          CREATE TABLE reminders (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists (id));
          INSERT INTO reminders VALUES (1, 7);
          """
        )
      }

      let fromTransaction = await #expect(throws: SQLiteFeatureUnavailableError.self) {
        try await driver.read { try $0.foreignKeyViolations() }
      }
      let fromWrite = await #expect(throws: SQLiteFeatureUnavailableError.self) {
        try await driver.write { try $0.foreignKeyViolations() }
      }
      let fromConnection = await #expect(throws: SQLiteFeatureUnavailableError.self) {
        try await driver.readWithoutTransaction { try $0.foreignKeyViolations() }
      }
      let fromWriteConnection = await #expect(throws: SQLiteFeatureUnavailableError.self) {
        try await driver.writeWithoutTransaction { try $0.foreignKeyViolations() }
      }
      #expect(fromTransaction == expected)
      #expect(fromWrite == expected)
      #expect(fromConnection == expected)
      #expect(fromWriteConnection == expected)
    }
  #endif
#endif
