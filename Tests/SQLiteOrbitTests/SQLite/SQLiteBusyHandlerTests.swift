#if BuiltInSQLite
  import Foundation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteBusyHandlerTests {
    @Test
    func theHandlerIsAskedAgainWithARisingAttemptUntilItGivesUp() async throws {
      try await withContendedDatabases { holder, open in
        let attempts = Lock([Int]())
        let waiter = try open(.limit(.seconds(30))) { attempt in
          attempts.withLock { $0.append(attempt) }
          // Giving up is what turns the wait into the `SQLITE_BUSY` the caller sees.
          return attempt < 3
        }

        let error = try await holder.holdingTheWriteLock {
          await #expect(throws: SQLiteError.self) {
            try await waiter.write { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
            }
          }
        }

        #expect(error?.primaryCode == .busy)
        #expect(attempts.withLock { $0 } == [1, 2, 3])
      }
    }

    @Test
    func theHandlerIsConsultedInsteadOfTheConfiguredBusyTimeout() async throws {
      try await withContendedDatabases { holder, open in
        let attempts = Lock(0)
        // A timeout long enough that waiting by it rather than by the handler would hang the test.
        let waiter = try open(.limit(.seconds(30))) { _ in
          attempts.withLock { $0 += 1 }
          return false
        }

        let clock = ContinuousClock()
        let started = clock.now
        let error = try await holder.holdingTheWriteLock {
          await #expect(throws: SQLiteError.self) {
            try await waiter.write { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
            }
          }
        }

        #expect(error?.primaryCode == .busy)
        #expect(attempts.withLock { $0 } == 1)
        #expect(clock.now - started < .seconds(5))
      }
    }

    @Test
    func theHandlerIsBackAfterAnAccessThatChangedTheBusyTimeout() async throws {
      try await withContendedDatabases { holder, open in
        let attempts = Lock(0)
        let waiter = try open(.limit(.seconds(30))) { _ in
          attempts.withLock { $0 += 1 }
          return false
        }

        // Setting the timeout is how SQLite replaces the handler, since it keeps only one.
        try await waiter.writeWithoutTransaction { connection in
          connection.busyTimeout = .limit(.seconds(42))
          let inEffect = try connection.fetchOne(busyTimeoutPragma)
          #expect(inEffect == 42_000)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let error = try await holder.holdingTheWriteLock {
          await #expect(throws: SQLiteError.self) {
            try await waiter.write { transaction in
              try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
            }
          }
        }

        // Had the handler not come back, the restored 30 second timeout would have waited instead.
        #expect(error?.primaryCode == .busy)
        #expect(attempts.withLock { $0 } == 1)
        #expect(clock.now - started < .seconds(5))
      }
    }

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
    let directory = try makeShortTemporaryDirectory("busy")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))

    let holder = try SQLiteQueue(path: path)
    try await holder.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }

    try await body(WriteLockHolder(database: holder)) { busyTimeout, handler in
      var configuration = SQLiteConfiguration.default
      configuration.busyTimeout = busyTimeout
      configuration.busyHandler = handler
      return try SQLiteQueue(path: path, configuration: configuration)
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
      let isHeld = Lock(false)
      let isReleased = Lock(false)
      let held = Task {
        try await database.write { transaction in
          try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          isHeld.withLock { $0 = true }
          while !isReleased.withLock({ $0 }) {}
        }
      }
      defer {
        isReleased.withLock { $0 = true }
      }
      try await waitUntil { isHeld.withLock { $0 } }
      let value = try await body()
      isReleased.withLock { $0 = true }
      try await held.value
      return value
    }
  }

  private let busyTimeoutPragma = #sql("PRAGMA busy_timeout", as: Int.self)
#endif
