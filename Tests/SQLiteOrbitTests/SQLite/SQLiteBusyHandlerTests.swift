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
          let waiter = try open(
            .handler { attempt in
              attempts.append(attempt)
              // Giving up is what turns the wait into the `SQLITE_BUSY` the caller sees.
              return attempt < 3
            }
          )

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
      func aHandlerSetForOneAccessGivesWayToTheConfiguredPolicyAfterwards() async throws {
        try await withContendedDatabases { holder, open in
          let attempts = TestCounter()
          let waiter = try open(.timeout(.zero))

          try await holder.holdingTheWriteLock {
            let error = await #expect(throws: SQLiteError.self) {
              try await waiter.writeWithoutTransaction { connection in
                try connection.setBusyPolicy(
                  .handler { _ in
                    attempts.increment()
                    return false
                  }
                )
                guard case .handler = connection.busyPolicy else {
                  Issue.record("The handler is not the policy in effect")
                  return
                }
                try connection.execute("INSERT INTO items (id) VALUES (2)")
              }
            }
            #expect(error?.isBusy == true)
            #expect(attempts.value == 1)

            // The configured timeout of zero is back, so nothing asks the handler again.
            await #expect(throws: SQLiteError.self) {
              try await waiter.write { transaction in
                try transaction.execute("INSERT INTO items (id) VALUES (2)")
              }
            }
            #expect(attempts.value == 1)
          }
        }
      }

      @Test
      func theHandlerIsBackAfterAnAccessThatChangedTheBusyTimeout() async throws {
        try await withContendedDatabases { holder, open in
          let attempts = TestCounter()
          let waiter = try open(
            .handler { _ in
              attempts.increment()
              return false
            }
          )

          // Setting the timeout is how SQLite replaces the handler, since it keeps only one.
          try await waiter.writeWithoutTransaction { connection in
            try connection.setBusyPolicy(.timeout(.seconds(42)))
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

          // Had the handler not come back, the 42 second timeout would have waited.
          #expect(error?.isBusy == true)
          #expect(attempts.value == 1)
          #expect(clock.now - started < .seconds(5))
        }
      }
      @Test
      func theHandlerSurvivesRetryingAFailedRestore() throws {
        try withTestDatabaseFile { file in
          let failRestore = Lock(false)
          let attempts = TestCounter()
          let install = builtInTestLibrary.busyHandler!.install
          var configuration = SQLiteConfiguration.default
          configuration.busyPolicy = .handler { _ in
            attempts.increment()
            return false
          }
          configuration.library.busyHandler = SQLiteLibrary.BusyHandler {
            connection,
            callback,
            data in
            if failRestore.withLock({ $0 }) { return SQLiteResultCode.ioError.rawValue }
            return install(connection, callback, data)
          }
          let waiter = try file.queue(configuration: configuration)
          let error = #expect(throws: SQLiteError.self) {
            try waiter.writeWithoutTransactionBlocking { connection in
              try connection.setBusyPolicy(.timeout(.milliseconds(42)))
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
    func aHandlerIsRefusedByALibraryThatCannotInstallOne() async throws {
      var configuration = SQLiteConfiguration.default
      configuration.library.busyHandler = nil
      configuration.busyPolicy = .handler { _ in false }

      let error = #expect(throws: SQLiteFeatureUnavailableError.self) {
        _ = try SQLiteQueue(path: .memory, configuration: configuration)
      }
      #expect(error?.feature == .busyHandler)

      configuration.busyPolicy = .timeout(.seconds(1))
      let queue = try SQLiteQueue(path: .memory, configuration: configuration)
      let scoped = await #expect(throws: SQLiteFeatureUnavailableError.self) {
        try await queue.writeWithoutTransaction { connection in
          try connection.withBusyPolicy(.handler { _ in false }) {}
        }
      }
      #expect(scoped?.feature == .busyHandler)
      let isTimeout = try await queue.readWithoutTransaction { connection in
        if case .timeout(.seconds(1)) = connection.busyPolicy { true } else { false }
      }
      #expect(isTimeout)
    }
  }

  /// Runs `body` with a database holding the write lock on demand, and a way to open a second
  /// database on the same file whose busy policy is the one under test.
  private func withContendedDatabases(
    _ body: (
      _ holder: WriteLockHolder,
      _ open: (SQLiteBusyPolicy) throws -> SQLiteQueue
    ) async throws -> Void
  ) async throws {
    try await withTestDatabaseFile("busy") { file in
      let holder = try file.queue()
      try await holder.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")

      try await body(WriteLockHolder(database: holder)) { busyPolicy in
        var configuration = SQLiteConfiguration.default
        configuration.busyPolicy = busyPolicy
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
