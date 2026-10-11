#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Suite(.timeLimit(.minutes(1)))
  struct SQLiteSerialConnectionTests {
    @Test
    func lendsTheConnectionForReadingAndWritingAsynchronouslyAndBlocking() async throws {
      let connection = try SQLiteSerialConnection(path: .memory, configuration: .default)
      try await connection.withWriteConnection { connection in
        try connection.transaction { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
          try transaction.execute("INSERT INTO items (id) VALUES (1)")
        }
      }
      try await withDeadline {
        try connection.withWriteConnectionBlocking { connection in
          try connection.execute("INSERT INTO items (id) VALUES (2)")
        }
      }

      let count = try await connection.withReadConnection { connection in
        try connection.transaction { transaction in
          try transaction.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
      }
      let blockingCount = try await withDeadline {
        try connection.withReadConnectionBlocking { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
      }
      #expect(count == 2)
      #expect(blockingCount == 2)
    }

    @Test
    func aReadAccessRefusesWritesAndAReadOnlyConnectionRefusesWriteAccess() async throws {
      try await withTemporaryDirectory("serial") { directory in
        let path = OrbitDatabasePath(directory.appending(path: "db.sqlite").path)
        let writable = try SQLiteSerialConnection(path: path, configuration: .default)
        try await writable.withWriteConnection { connection in
          try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        await #expect(throws: SQLiteError.self) {
          try await writable.withReadConnection { connection in
            try connection.fetchOne("INSERT INTO items (id) VALUES (1) RETURNING id") {
              $0[0].integerValue
            }
          }
        }

        let readOnly = try SQLiteSerialConnection(
          path: path,
          configuration: .default,
          flags: [.readOnly, .noMutex]
        )
        let ran = TestCounter()
        let error = await #expect(throws: SQLiteError.self) {
          try await readOnly.withWriteConnection { _ in ran.increment() }
        }
        #expect(error?.primaryCode == .readOnly)
        #expect(ran.value == 0)
        let count = try await readOnly.withReadConnection { connection in
          try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
        }
        #expect(count == 0)
      }
    }

    @Test
    func driverSetupsRunAfterTheConfigurationsAndAreNotPartOfIt() async throws {
      let order = TestRecorder<String>()
      var configuration = SQLiteConfiguration.default
      configuration.setups = [SQLiteSetup { _ in order.append("configuration") }]
      let connection = try SQLiteSerialConnection(
        path: .memory,
        configuration: configuration,
        setups: [SQLiteSetup { _ in order.append("driver") }, .sql("PRAGMA user_version = 7")]
      )
      #expect(order.values == ["configuration", "driver"])

      let (version, setupCount) = try await connection.withReadConnection { connection in
        (
          try connection.fetchOne("PRAGMA user_version") { $0[0].integerValue },
          connection.configuration.setups.count
        )
      }
      #expect(version == 7)
      #expect(setupCount == 1)
    }

    #if !Turso
      @Test
      func driverSetupsAreExemptFromTheConfigurationsAuthorization() async throws {
        var configuration = SQLiteConfiguration.default
        configuration.authorization = { authorization in
          switch authorization.action {
          case .pragma(name: "user_version", value: .some): .deny
          default: .allow
          }
        }
        let connection = try SQLiteSerialConnection(
          path: .memory,
          configuration: configuration,
          setups: [.sql("PRAGMA user_version = 7")]
        )

        // The same statement from the application is still subject to its policy.
        let error = await #expect(throws: SQLiteError.self) {
          try await connection.withWriteConnection { connection in
            try connection.execute("PRAGMA user_version = 8")
          }
        }
        #expect(error?.primaryCode == .auth)
        let version = try await connection.withReadConnection { connection in
          try connection.fetchOne("PRAGMA user_version") { $0[0].integerValue }
        }
        #expect(version == 7)

        // Setups the configuration carries are not exempt.
        configuration.setups = [.sql("PRAGMA user_version = 9")]
        await #expect(throws: SQLiteError.self) {
          _ = try SQLiteSerialConnection(path: .memory, configuration: configuration)
        }
      }
    #endif

    // Turso reports a recursive query as one that may write, which a read refuses.
    #if !Turso
      @Test
      func cancellingTheTaskInterruptsTheAccessAndThrowsCancellationError() async throws {
        let connection = try SQLiteSerialConnection(path: .memory, configuration: .default)
        let started = TestCounter()
        let access = Task {
          try await connection.withReadConnection { connection in
            started.increment()
            // Counts until interrupted.
            return try connection.transaction { transaction in
              try transaction.fetchOne(
                """
                WITH RECURSIVE counter(n) AS (
                  SELECT 1 UNION ALL SELECT n + 1 FROM counter WHERE n < 2000000000
                )
                SELECT count(*) FROM counter
                """
              ) { $0[0].integerValue }
            }
          }
        }
        try await waitUntil { started.value == 1 }
        // Give the query time to start stepping, which is what an interrupt stops.
        try await Task.sleep(for: .milliseconds(50))
        access.cancel()
        await #expect(throws: CancellationError.self) { try await access.value }

        // The connection is usable again once the interrupted access has ended.
        let value = try await connection.withReadConnection { connection in
          try connection.fetchOne("SELECT 1") { $0[0].integerValue }
        }
        #expect(value == 1)
      }
    #endif

    @Test
    func aSerialConnectionAndACompositeObserverMakeAnObservableDatabase() async throws {
      let database = try TinyQueue(path: .memory)
      try await database.write { try $0.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)") }

      let commits = TestRecorder<OrbitDatabaseCommit>()
      let observer = CommitObserver(commits: commits)
      // The composite reports every transaction, whatever region a member was registered for.
      let subscription = try database.subscribe(
        transactionObserver: observer,
        region: OrbitDatabaseRegion(table: "elsewhere")
      )
      try await database.write { try $0.execute("INSERT INTO items (id) VALUES (1)") }
      #expect(commits.values.count == 1)
      #expect(commits.values.first?.origin == .local)
      #expect(subscription.region == OrbitDatabaseRegion(table: "elsewhere"))

      let count = try database.readBlocking { transaction in
        try transaction.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue }
      }
      #expect(count == 1)

      subscription.cancel()
      try await database.write { try $0.execute("INSERT INTO items (id) VALUES (2)") }
      #expect(commits.values.count == 1)
    }
  }

  private struct CommitObserver: OrbitDatabaseTransactionObserver {
    let commits: TestRecorder<OrbitDatabaseCommit>

    func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
      commits.append(commit)
    }
  }

  /// A minimal observable driver, built only from public building blocks.
  private final class TinyQueue: OrbitDatabaseWriter, OrbitObservableDatabase {
    private let connection: SQLiteSerialConnection
    private let observers = OrbitCompositeDatabaseTransactionObserver()

    init(path: OrbitDatabasePath) throws {
      connection = try SQLiteSerialConnection(path: path, configuration: .default)
    }

    func read<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) async throws -> Result {
      try await connection.withReadConnection { connection in
        try connection.transaction(observer: observers, body)
      }
    }

    func readBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) throws -> Result {
      try connection.withReadConnectionBlocking { connection in
        try connection.transaction(observer: observers, body)
      }
    }

    func readWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) async throws -> Result {
      try await connection.withReadConnection { connection in
        try connection.withObservation(observers) { try body(connection) }
      }
    }

    func readWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) throws -> Result {
      try connection.withReadConnectionBlocking { connection in
        try connection.withObservation(observers) { try body(connection) }
      }
    }

    func write<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) async throws -> Result {
      try await connection.withWriteConnection { connection in
        try connection.transaction(observer: observers, body)
      }
    }

    func writeBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result {
      try connection.withWriteConnectionBlocking { connection in
        try connection.transaction(observer: observers, body)
      }
    }

    func writeWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) async throws -> Result {
      try await connection.withWriteConnection { connection in
        try connection.withObservation(observers) { try body(connection) }
      }
    }

    func writeWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) throws -> Result {
      try connection.withWriteConnectionBlocking { connection in
        try connection.withObservation(observers) { try body(connection) }
      }
    }

    func subscribe(
      transactionObserver: any OrbitDatabaseTransactionObserver,
      region: OrbitDatabaseRegion
    ) throws -> OrbitRegionSubscription {
      observers.subscribe(transactionObserver, region: region)
    }
  }
#endif
