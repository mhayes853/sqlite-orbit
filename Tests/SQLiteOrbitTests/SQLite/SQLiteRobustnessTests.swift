#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Foundation
    import StructuredQueries
    import Testing

    @testable import SQLiteOrbit

    private func openConnection(
      configuration: SQLiteConfiguration = .default
    ) throws -> SQLiteConnection {
      let handle = try SQLiteConnection.open(
        path: ":memory:",
        flags: [.readWrite, .create, .memory, .noMutex],
        configuration: configuration
      )
      try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
      return handle
    }

    private final class StatementLifecycleProbe: Sendable {
      let prepared = TestCounter()
      let finalized = TestCounter()
      private let cachedPointers = Lock<Set<UInt>>([])

      func configuration(matching sqlPrefix: String) -> SQLiteConfiguration {
        let base = builtInTestLibrary
        var configuration = SQLiteConfiguration.default
        configuration.library.statements.preparation.prepare = LibraryHooks.prepare {
          [self]
          connection,
          sql,
          count,
          flags,
          statement,
          tail in
          let code = base.statements.preparation.prepare(
            connection,
            sql,
            count,
            flags,
            statement,
            tail
          )
          // Metadata probes use flags=0; only track statements prepared for the cache.
          if code == SQLiteResultCode.ok.rawValue, let pointer = statement?.pointee,
            flags & SQLitePrepareFlags.persistent.rawValue != 0,
            let sql, String(cString: sql).hasPrefix(sqlPrefix)
          {
            cachedPointers.withLock { _ = $0.insert(UInt(bitPattern: pointer)) }
            prepared.increment()
          }
          return code
        }
        configuration.library.statements.execution.finalize = LibraryHooks.finalize {
          [self] statement in
          if let statement,
            cachedPointers.withLock({ $0.remove(UInt(bitPattern: statement)) != nil })
          {
            finalized.increment()
          }
          return base.statements.execution.finalize(statement)
        }
        return configuration
      }
    }

    @Test
    func rawSQLStopsAtAnEmbeddedNulTheWaySQLiteDoes() throws {
      var handle = try openConnection()
      try handle.execute(
        "INSERT INTO items (id, title) VALUES (1, 'a');\u{0}INSERT INTO items (id, title) VALUES (2, 'b')"
      )
      let count = try handle.read { transaction in
        try #sql("SELECT count(*) FROM items", as: Int.self).fetchAll(transaction)
      }
      // SQLite reads SQL text up to the first NUL whatever length it is given, so the second
      // statement here is not run. Values are a different matter: those keep their NULs, which is
      // what `textRoundTripsWhateverCharactersItHolds` pins down.
      #expect(count == [1])
    }

    @Test
    func aReadOnAWritableConnectionRefusesToMutateAndLeavesItWritable() throws {
      var handle = try openConnection()

      // The connection can write, but not while lending a read transaction: a mutation that was
      // merely rolled back at the end of the read would look like it had worked.
      #expect(throws: SQLiteError.self) {
        try handle.read { transaction in
          try #sql(
            "INSERT INTO items (id, title) VALUES (1, 'nope') RETURNING id",
            as: Int.self
          )
          .fetchAll(transaction)
        }
      }

      // A read that threw turns `query_only` back off on its way out too.
      #expect(throws: TestError()) {
        try handle.read { _ in throw TestError() }
      }

      // And the connection is writable again afterwards.
      try handle.write { transaction in
        try Item.insert { Item(id: 1, title: "yes") }.execute(transaction)
      }
      let titles = try handle.read { transaction in
        try Item.select(\.title).fetchAll(transaction)
      }
      #expect(titles == ["yes"])
    }

    @Test
    func aReadAfterAWriteRefusesRawAndCachedMutations() throws {
      var handle = try openConnection()
      let insert = "INSERT INTO items (title) VALUES ('nope')"

      // Compiled while the connection could write, and kept: the cache keeps the first, and the
      // second is a raw statement this test holds across the accesses.
      let held = try handle.withWriteConnection { connection in
        try connection.execute(SQL(text: insert))
        let library = connection.sqlite
        let statement = try #require(
          try library.prepare(
            insert,
            on: connection.sqliteConnection,
            flags: SQLitePrepareFlags.persistent.rawValue
          )
        )
        return UInt(bitPattern: statement)
      }
      let statement = try #require(OpaquePointer(bitPattern: held))
      let library = handle.configuration.library
      defer { _ = library.statements.execution.finalize(statement) }

      try handle.withReadConnection { connection in
        // The cached statement is held to the read when it is lent.
        #expect(throws: SQLiteError.self) {
          _ = try connection.rowCursor(SQL(text: insert), cached: true)
        }
        // Raw SQL, compiled anew or compiled before the read began, is refused by the library
        // itself: SQLite refuses to step either, and Turso to compile the new one and, with a
        // generic error, to step the old one.
        #if Turso
          #expect(throws: SQLiteError.self) {
            try library.prepare(insert, on: connection.sqliteConnection)
          }
          let refusal = SQLiteResultCode.error.rawValue
        #else
          let raw = try #require(try library.prepare(insert, on: connection.sqliteConnection))
          defer { _ = library.statements.execution.finalize(raw) }
          let refusal = SQLiteResultCode.readOnly.rawValue
          #expect(library.statements.execution.step(raw) & 0xff == refusal)
        #endif
        #expect(library.statements.execution.step(statement) & 0xff == refusal)
        _ = library.statements.execution.reset(statement)
      }

      // The next write can write again, through either statement.
      try handle.withWriteConnection { connection in
        #expect(library.statements.execution.step(statement) == SQLiteResultCode.done.rawValue)
        _ = library.statements.execution.reset(statement)
        try connection.execute(SQL(text: insert))
      }
      let count = try handle.read { transaction in
        try #sql("SELECT count(*) FROM items", as: Int.self).fetchOne(transaction)
      }
      #expect(count == 3)
    }

    @Test(.libraryHooks)
    func consecutiveReadsOnAWritableConnectionReuseTheirStatements() throws {
      let probe = StatementLifecycleProbe()
      do {
        var handle = try openConnection(
          configuration: probe.configuration(matching: "SELECT title FROM items")
        )
        try handle.write { transaction in
          try Item.insert { Item(id: 1, title: "kept") }.execute(transaction)
        }
        for _ in 0..<5 {
          let titles = try handle.read { transaction in
            try #sql("SELECT title FROM items", as: String.self).fetchAll(transaction)
          }
          #expect(titles == ["kept"])
        }
        // Compiled once and never dropped: nothing between the reads expired it, so its first
        // step never found it recompiled and emptied the cache.
        #expect(probe.prepared.value == 1)
        #expect(probe.finalized.value == 0)

        // A write between reads still leaves the statement where the next read finds it.
        try handle.write { transaction in
          try Item.insert { Item(id: 2, title: "also") }.execute(transaction)
        }
        let titles = try handle.read { transaction in
          try #sql("SELECT title FROM items ORDER BY id", as: String.self).fetchAll(transaction)
        }
        #expect(titles == ["kept", "also"])
      }
    }

    #if !Turso
      @Test
      func aWritableConnectionClosedAfterAReadStillRemovesItsLog() throws {
        try withTestDatabaseFile("wal") { file in
          let log = file.url.path + "-wal"
          do {
            var configuration = SQLiteConfiguration.default
            configuration.journalMode = .wal
            var handle = try SQLiteConnection(path: file.path, configuration: configuration)
            try handle.write { transaction in
              try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
              try transaction.execute("INSERT INTO items (id) VALUES (1)")
            }
            #expect(FileManager.default.fileExists(atPath: log))
            // Closed while query-only, which a read leaves it.
            let count = try handle.read { transaction in
              try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self)
            }
            #expect(count == 1)
          }
          // The last connection to close checkpoints the log into the database and removes it.
          #expect(!FileManager.default.fileExists(atPath: log))
          var handle = try SQLiteConnection(path: file.path, configuration: .default)
          let count = try handle.read { transaction in
            try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self)
          }
          #expect(count == 1)
        }
      }
    #endif

    @Test(.libraryHooks)
    func aStatementIsReusableAfterTheQueryUsingItFails() throws {
      let probe = StatementLifecycleProbe()
      do {
        var handle = try openConnection(
          configuration: probe.configuration(matching: "SELECT title FROM items")
        )
        try handle.write { transaction in
          try Item.insert { Item(id: 1, title: "kept") }.execute(transaction)
        }

        // Decoding the title as an integer fails partway through the cursor's life.
        try handle.read { transaction in
          _ = #expect(throws: OrbitDatabaseColumnDecodingError.self) {
            _ = try #sql("SELECT title FROM items", as: Int.self).fetchAll(transaction)
          }
        }

        // The statement went back to the cache in a usable state rather than mid-scan.
        let titles = try handle.read { transaction in
          try #sql("SELECT title FROM items", as: String.self).fetchAll(transaction)
        }
        #expect(titles == ["kept"])
        #expect(probe.prepared.value == 1)
        #expect(probe.finalized.value == 0)
      }
      #expect(probe.finalized.value == probe.prepared.value)
    }

    @Test(.libraryHooks)
    func aPartiallyReadCursorDoesNotResumeWhenItsStatementIsReused() throws {
      let probe = StatementLifecycleProbe()
      do {
        var handle = try openConnection(
          configuration: probe.configuration(matching: "SELECT title FROM items")
        )
        try handle.write { transaction in
          for id in 1...3 {
            try Item.insert { Item(id: id, title: "item \(id)") }.execute(transaction)
          }
        }

        try handle.read { transaction in
          // Abandon the cursor after one row, so its statement goes back to the cache mid-scan.
          var cursor = try transaction.fetchCursor(
            "SELECT title FROM items ORDER BY id",
            as: String.self,
            cached: true
          )
          #expect(try cursor.next() == "item 1")
        }

        let titles = try handle.read { transaction in
          try #sql("SELECT title FROM items ORDER BY id", as: String.self).fetchAll(transaction)
        }
        // A statement that was not reset would start from the second row.
        #expect(titles == ["item 1", "item 2", "item 3"])
        #expect(probe.prepared.value == 1)
        #expect(probe.finalized.value == 0)
      }
      #expect(probe.finalized.value == probe.prepared.value)
    }

    @Test
    func aCachedStatementAbandonedAfterOneRowTakesItsNextBindings() throws {
      var handle = try openConnection()
      try handle.write { transaction in
        for id in 1...4 {
          try Item.insert { Item(id: id, title: "item \(id)") }.execute(transaction)
        }
      }

      // `fetchOne` caches its statement and abandons the cursor after a single row, so the very same
      // statement comes back for the next call, which binds a different value to it.
      let first = try handle.read { transaction in
        try #sql("SELECT title FROM items WHERE id > \(bind: 1) ORDER BY id", as: String.self)
          .fetchOne(transaction)
      }
      let second = try handle.read { transaction in
        try #sql("SELECT title FROM items WHERE id > \(bind: 3) ORDER BY id", as: String.self)
          .fetchOne(transaction)
      }

      #expect(first == "item 2")
      // A statement still carrying the first call's binding, or still standing on its second row,
      // would answer with something else.
      #expect(second == "item 4")
    }

    @Test
    func aCacheThatHoldsNothingStillRunsQueries() throws {
      var configuration = SQLiteConfiguration.default
      configuration.maximumCachedStatements = 0
      var handle = try openConnection(configuration: configuration)

      try handle.write { transaction in
        try Item.insert { Item(id: 1, title: "uncached") }.execute(transaction)
      }
      let titles = try handle.read { transaction in
        try Item.select(\.title).fetchAll(transaction)
      }
      #expect(titles == ["uncached"])
    }

    @Test
    func largeIntegersRoundTripWithoutLosingPrecision() throws {
      var handle = try openConnection()
      try handle.execute("CREATE TABLE numbers (value INTEGER)")

      let extremes: [Int64] = [.min, -1, 0, 1, .max]
      for value in extremes {
        try handle.write { transaction in
          try #sql("INSERT INTO numbers (value) VALUES (\(value, as: Int64.self))", as: Void.self)
            .execute(transaction)
        }
      }

      let stored = try handle.read { transaction in
        try #sql("SELECT value FROM numbers", as: Int64.self).fetchAll(transaction)
      }
      #expect(stored == extremes)
    }

    @Test(.libraryHooks)
    func anUnsignedValueTooLargeForSQLiteIsReportedAndLeavesTheCacheUsable() throws {
      let probe = StatementLifecycleProbe()
      do {
        var handle = try openConnection(
          configuration: probe.configuration(matching: "INSERT INTO numbers")
        )
        try handle.execute("CREATE TABLE numbers (value INTEGER)")

        // SQLite stores signed 64-bit integers, so this cannot be represented, and is reported
        // rather than wrapped.
        for _ in 0..<3 {
          #expect(throws: OrbitDatabaseIntegerOverflowError<UInt64>.self) {
            try handle.write { transaction in
              _ = try #sql(
                "INSERT INTO numbers (value) VALUES (\(UInt64.max)) RETURNING value",
                as: UInt64.self
              )
              .fetchAll(transaction)
            }
          }
        }

        // The statement that failed to bind was given back, so the cache did not leak it.
        try handle.write { transaction in
          _ = try #sql(
            "INSERT INTO numbers (value) VALUES (\(UInt64(1))) RETURNING value",
            as: UInt64.self
          )
          .fetchAll(transaction)
        }
        let stored = try handle.read { transaction in
          try #sql("SELECT value FROM numbers", as: Int.self).fetchAll(transaction)
        }
        #expect(stored == [1])
        #expect(probe.prepared.value == 1)
        #expect(probe.finalized.value == 0)
      }
      #expect(probe.finalized.value == probe.prepared.value)
    }

    @Test
    func textRoundTripsWhateverCharactersItHolds() throws {
      var handle = try openConnection()
      // Binding with a byte count of -1 would ask SQLite to stop at the first NUL, which would
      // silently truncate the last of these to "before".
      let titles = ["Blob’s reminder", "日本語", "🧑‍🚀 emoji", "", "before\u{0}after"]

      try handle.write { transaction in
        for (id, title) in titles.enumerated() {
          try Item.insert { Item(id: id + 1, title: title) }.execute(transaction)
        }
      }
      let stored = try handle.read { transaction in
        try Item.all.order { $0.id }.fetchAll(transaction).map(\.title)
      }
      #expect(stored == titles)
    }

    private final class ConnectionCounter: Sendable {
      private let state = Lock((opened: 0, closed: 0))

      var opened: Int { state.withLock { $0.opened } }
      var closed: Int { state.withLock { $0.closed } }

      var library: SQLiteLibrary {
        let base = builtInTestLibrary
        var library = base
        library.connections.open = LibraryHooks.open { path, connection, flags, vfs in
          let code = base.connections.open(path, connection, flags, vfs)
          if code == SQLiteResultCode.ok.rawValue {
            self.state.withLock { $0.opened += 1 }
          }
          return code
        }
        library.connections.close = LibraryHooks.close { connection in
          self.state.withLock { $0.closed += 1 }
          return base.connections.close(connection)
        }
        return library
      }
    }

    @Test(.libraryHooks)
    func releasingAPoolClosesEveryConnectionItOpened() async throws {
      let counter = ConnectionCounter()
      var configuration = SQLiteConfiguration.default
      configuration.library = counter.library

      try await withTestDatabaseFile { file in
        do {
          let driver = try SQLitePool(path: file.path, configuration: configuration, readerCount: 3)
          try await driver.write { transaction in
            try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
          }
          #expect(counter.opened == 4)
          #expect(counter.closed == 0)
        }

        // Nothing else holds these connections, so every one of them must have been closed. A driver
        // that leaked them would exhaust file descriptors in any process that opens databases often.
        try await waitUntil { counter.closed >= counter.opened }
        #expect(counter.closed == counter.opened)
      }
    }

    @Test
    func aPoolSurvivesAStormOfCancellations() async throws {
      try await withTestDatabaseFile { file in
        let driver = try SQLitePool(path: file.path, readerCount: 2)
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }

        // A third of these are cancelled immediately, often while still queued for a reader or the
        // writer. Whatever they were holding has to come back either way.
        await withTaskGroup(of: Void.self) { group in
          for index in 0..<200 {
            group.addTask {
              let task = Task {
                if index.isMultiple(of: 2) {
                  _ = try await driver.read { transaction in
                    try #sql("SELECT count(*) FROM items", as: Int.self).fetchAll(transaction)
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
              do {
                try await task.value
              } catch is CancellationError {
                #expect(index.isMultiple(of: 3), "Uncancelled access \(index) failed")
              } catch {
                Issue.record(error, "Unexpected failure for access \(index)")
              }
            }
          }
          await group.waitForAll()
        }

        // Every reader and the writer came back, so the pool still works.
        let count = try await driver.read { transaction in
          try #sql("SELECT count(*) FROM items", as: Int.self).fetchAll(transaction)
        }
        #expect(count.count == 1)
        try await driver.write { transaction in
          try transaction.execute("INSERT INTO items (id) VALUES (NULL)")
        }
      }
    }

    @Test
    func cancelledWritesNeverCommitWithoutReturningSuccess() async throws {
      try await withTestDatabaseFile { file in
        let driver = try SQLitePool(path: file.path)
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }

        let writes = (1...300)
          .map { id in
            Task {
              try await driver.write { transaction in
                try transaction.executeScript("INSERT INTO items (id) VALUES (\(id))")
                return id
              }
            }
          }
        for (offset, write) in writes.enumerated() where offset.isMultiple(of: 2) {
          write.cancel()
        }

        var successfulIDs: [Int] = []
        for (offset, write) in writes.enumerated() {
          do {
            successfulIDs.append(try await write.value)
          } catch is CancellationError {
            #expect(offset.isMultiple(of: 2), "Uncancelled write \(offset + 1) failed")
          } catch {
            Issue.record(error, "Unexpected failure for write \(offset + 1)")
          }
        }
        #expect(Set(successfulIDs).isSuperset(of: stride(from: 2, through: 300, by: 2)))
        let storedIDs = try await driver.read { transaction in
          try #sql("SELECT id FROM items ORDER BY id", as: Int.self).fetchAll(transaction)
        }

        // Cancellation may win or lose a race with a fast write, but a committed transaction must
        // always be reported as successful and a failed one must leave no row behind.
        #expect(storedIDs == successfulIDs.sorted())
      }
    }

    @Test
    func aReaderSeesWhatAnotherConnectionCommitted() async throws {
      try await withTestDatabaseFile { file in
        // Two drivers on one file stand in for two processes sharing a database.
        let writer = try SQLitePool(path: file.path)
        let reader = try SQLitePool(path: file.path)
        try await writer.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }

        for id in 1...5 {
          try await writer.write { transaction in
            try transaction.executeScript("INSERT INTO items (id) VALUES (\(id))")
          }
          // Each read takes a fresh snapshot, so it must see everything committed before it.
          let count = try await reader.read { transaction in
            try #sql("SELECT count(*) FROM items", as: Int.self).fetchAll(transaction)
          }
          #expect(count == [id])
        }
      }
    }

    @Test
    func writesFromTwoConnectionsQueueRatherThanFail() async throws {
      try await withTestDatabaseFile { file in
        let first = try SQLitePool(path: file.path)
        let second = try SQLitePool(path: file.path)
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
          try #sql("SELECT count(*) FROM items", as: Int.self).fetchAll(transaction)
        }
        #expect(count == [60])
      }
    }

    @Test
    func decodingNullIntoANonOptionalIsReportedRatherThanCrashing() throws {
      var handle = try openConnection()
      try handle.execute("CREATE TABLE numbers (value INTEGER)")
      try handle.write { transaction in
        try transaction.execute("INSERT INTO numbers (value) VALUES (NULL)")
      }

      #expect(throws: (any Error).self) {
        try handle.read { transaction in
          _ = try #sql("SELECT value FROM numbers", as: Int.self).fetchAll(transaction)
        }
      }

      // The failed decode did not leave the connection unusable.
      let values = try handle.read { transaction in
        try #sql("SELECT value FROM numbers", as: Int?.self).fetchAll(transaction)
      }
      #expect(values == [Int?.none])
    }

    @Table
    private struct Item: Equatable, Sendable {
      let id: Int
      var title: String
    }

    @Test(.libraryHooks)
    func aTransactionInterruptedWhileItEndsIsNotLeftOpen() throws {
      let base = builtInTestLibrary
      let isArmed = Lock(true)
      var configuration = SQLiteConfiguration.default
      configuration.library.statements.execution.step = LibraryHooks.step { statement in
        let sql = base.statements.inspection.sql(statement).map { String(cString: $0) }
        guard sql == "ROLLBACK", isArmed.withLock({ $0 }) else {
          return base.statements.execution.step(statement)
        }
        isArmed.withLock { $0 = false }
        return SQLiteResultCode.interrupt.rawValue
      }
      var handle = try openConnection(configuration: configuration)

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
        try #sql("SELECT title FROM items", as: String.self).fetchAll(transaction)
      }
      #expect(titles == ["after"])
    }

    @Test
    func aValueTooLargeForA32BitIntIsReportedRatherThanTrapping() throws {
      var handle = try openConnection()
      try handle.execute("CREATE TABLE numbers (value INTEGER)")
      try handle.write { transaction in
        try #sql("INSERT INTO numbers (value) VALUES (\(Int64.max, as: Int64.self))", as: Void.self)
          .execute(transaction)
      }

      let asInt64 = try handle.read { transaction in
        try #sql("SELECT value FROM numbers", as: Int64.self).fetchAll(transaction)
      }
      #expect(asInt64 == [Int64.max])

      let asInt = try handle.read { transaction in
        Result { try #sql("SELECT value FROM numbers", as: Int.self).fetchAll(transaction) }
      }
      if Int.bitWidth == 64 {
        #expect(try asInt.get() == [Int(Int64.max)])
      } else {
        #expect(throws: OrbitDatabaseIntegerOverflowError<Int64>.self) { try asInt.get() }
      }
    }
  #endif
#endif
