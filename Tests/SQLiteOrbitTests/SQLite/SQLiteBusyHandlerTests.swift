#if BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteBusyHandlerTests {
    // Turso's header does not declare `sqlite3_busy_handler`, so its library has no busy handler to
    // install and refuses the configuration, as the last test here checks for any such library.
    #if !Turso
      @Test
      func theHandlerIsAskedAgainWithARisingAttemptUntilItGivesUp() async throws {
        try await withContendedDatabases { holder, open in
          let attempts = TestRecorder<Int>()
          let waiter = try open(.limit(.seconds(30))) { attempt in
            attempts.append(attempt)
            // Giving up is what turns the wait into the `SQLITE_BUSY` the caller sees.
            return attempt < 3
          }

          let error = try await holder.holdingTheWriteLock {
            await #expect(throws: SQLiteError.self) {
              try await waiter.write { transaction in
                try transaction.execute("INSERT INTO items (id) VALUES (2)")
              }
            }
          }

          #expect(error?.isBusy == true)
          #expect(attempts.values == [1, 2, 3])
        }
      }

      @Test
      func theHandlerIsConsultedInsteadOfTheConfiguredBusyTimeout() async throws {
        try await withContendedDatabases { holder, open in
          let attempts = TestCounter()
          // A timeout long enough that waiting by it rather than the handler would hang the test.
          let waiter = try open(.limit(.seconds(30))) { _ in
            attempts.increment()
            return false
          }

          let clock = ContinuousClock()
          let started = clock.now
          let error = try await holder.holdingTheWriteLock {
            await #expect(throws: SQLiteError.self) {
              try await waiter.write { transaction in
                try transaction.execute("INSERT INTO items (id) VALUES (2)")
              }
            }
          }

          #expect(error?.isBusy == true)
          #expect(attempts.value == 1)
          #expect(clock.now - started < .seconds(5))
        }
      }

      @Test
      func theHandlerIsBackAfterAnAccessThatChangedTheBusyTimeout() async throws {
        try await withContendedDatabases { holder, open in
          let attempts = TestCounter()
          let waiter = try open(.limit(.seconds(30))) { _ in
            attempts.increment()
            return false
          }

          // Setting the timeout is how SQLite replaces the handler, since it keeps only one.
          try await waiter.writeWithoutTransaction { connection in
            try connection.setBusyTimeout(.limit(.seconds(42)))
            let inEffect = try connection.fetchOne(busyTimeoutPragma, as: Int.self)
            #expect(inEffect == 42_000)
          }

          let clock = ContinuousClock()
          let started = clock.now
          let error = try await holder.holdingTheWriteLock {
            await #expect(throws: SQLiteError.self) {
              try await waiter.write { transaction in
                try transaction.execute("INSERT INTO items (id) VALUES (2)")
              }
            }
          }

          // Had the handler not come back, the restored 30 second timeout would have waited.
          #expect(error?.isBusy == true)
          #expect(attempts.value == 1)
          #expect(clock.now - started < .seconds(5))
        }
      }
      @Test
      func theHandlerSurvivesRetryingAFailedTimeoutRestore() throws {
        try withTestDatabaseFile { file in
          let failRestore = Lock(false)
          let attempts = TestCounter()
          let base = builtInTestLibrary
          var configuration = SQLiteConfiguration.default
          configuration.busyTimeout = .limit(.milliseconds(30))
          configuration.busyHandler = { _ in
            attempts.increment()
            return false
          }
          configuration.library.connections.setBusyTimeout = { connection, milliseconds in
            if milliseconds == 30, failRestore.withLock({ $0 }) {
              return SQLiteResultCode.ioError.rawValue
            }
            return base.connections.setBusyTimeout(connection, milliseconds)
          }
          let waiter = try file.queue(configuration: configuration)
          let error = #expect(throws: SQLiteError.self) {
            try waiter.writeWithoutTransactionBlocking { connection in
              try connection.setBusyTimeout(.limit(.milliseconds(42)))
              failRestore.withLock { $0 = true }
            }
          }
          #expect(error?.primaryCode == .ioError)
          failRestore.withLock { $0 = false }

          var holder = try SQLiteConnection(path: file.path, configuration: .default)
          try holder.withWriteConnection { connection in
            try connection.transaction { _ in
              let blocked = #expect(throws: SQLiteError.self) {
                try waiter.writeBlocking { _ in Issue.record("Another connection holds the lock") }
              }
              #expect(blocked?.isBusy == true)
            }
          }
          #expect(attempts.value == 1)
        }
      }
    #endif

    @Test
    func aHandlerIsRefusedByALibraryThatCannotInstallOne() throws {
      var configuration = SQLiteConfiguration.default
      configuration.library.busyHandler = nil
      configuration.busyHandler = { _ in false }

      #expect(throws: SQLiteFeatureUnavailableError.self) {
        _ = try SQLiteQueue(path: .memory, configuration: configuration)
      }
    }
  }

  /// Runs `body` with a database holding the write lock on demand, and a way to open a second
  /// database on the same file whose busy handler is the one under test.
  private func withContendedDatabases(
    _ body: (
      _ holder: WriteLockHolder,
      _ open: (SQLiteBusyTimeout, @escaping @Sendable (Int) -> Bool) throws -> SQLiteQueue
    ) async throws -> Void
  ) async throws {
    try await withTestDatabaseFile("busy") { file in
      let holder = try file.queue()
      try await holder.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")

      try await body(WriteLockHolder(database: holder)) { busyTimeout, handler in
        var configuration = SQLiteConfiguration.default
        configuration.busyTimeout = busyTimeout
        configuration.busyHandler = handler
        return try file.queue(configuration: configuration)
      }
    }
  }

  /// A database that can be made to sit inside a write transaction while something else runs.
  private struct WriteLockHolder: Sendable {
    let database: SQLiteQueue

    /// Holds the write lock for the duration of `body`.
    ///
    /// The transaction is held by blocking the connection's own thread, which is the only way a
    /// lock stays taken across an `await` on another task.
    func holdingTheWriteLock<Result: Sendable>(
      _ body: () async throws -> Result
    ) async throws -> Result {
      let gate = TestGate()
      let held = Task {
        try await database.write { transaction in
          try transaction.execute("INSERT INTO items (id) VALUES (1)")
          try gate.enter()
        }
      }
      defer { gate.open() }
      try await gate.waitUntilEntered()
      let value = try await body()
      gate.open()
      try await held.value
      return value
    }
  }

  private let busyTimeoutPragma: SQL = "PRAGMA busy_timeout"
#endif
