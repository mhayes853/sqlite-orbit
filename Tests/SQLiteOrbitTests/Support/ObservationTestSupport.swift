#if BuiltInSQLite
  import StructuredQueriesSQLite

  @testable import SQLiteOrbit

  // MARK: - The items table

  // Observation tests mostly watch one table and count its rows, so that a write is a row
  // inserted and a value is how many there are.

  /// An in-memory database with the table `items`, with an integer primary key `id` and nothing
  /// else.
  func itemsDatabase() async throws -> SQLiteQueue {
    let database = try inMemoryDatabase()
    try await database.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
    return database
  }

  /// The database ``itemsDatabase()`` makes, made without suspending.
  func blockingItemsDatabase() throws -> SQLiteQueue {
    let database = try inMemoryDatabase()
    try database.executeBlocking(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
    return database
  }

  /// Inserts a row into `items` for each of `ids`, in one write transaction.
  func insertItems(_ ids: Int..., into database: some OrbitDatabaseWriter) async throws {
    try await database.write { transaction in
      for id in ids {
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (\(bind: id))", as: Void.self))
      }
    }
  }

  /// Inserts a row into `items` for each of `ids`, in one write transaction, blocking the calling
  /// thread.
  func insertItemsBlocking(_ ids: Int..., into database: some OrbitDatabaseWriter) throws {
    try database.writeBlocking { transaction in
      for id in ids {
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (\(bind: id))", as: Void.self))
      }
    }
  }

  /// The number of rows in `items`, as a fetch reads it.
  let itemCountQuery = #sql("SELECT count(*) FROM items", as: Int.self)

  // MARK: - A view redefined under a cached statement

  /// Two tables of titles, and the view `current_items` reading the first of them.
  ///
  /// A statement reading the view, once cached, is recompiled by SQLite when
  /// ``currentItemsViewRedefinition`` points the view at the other table, which is how a test
  /// changes what a statement reads without changing its SQL.
  let currentItemsViewSchema = """
    CREATE TABLE original_items (title TEXT NOT NULL);
    CREATE TABLE alternate_items (title TEXT NOT NULL);
    INSERT INTO original_items VALUES ('Original');
    INSERT INTO alternate_items VALUES ('Alternate');
    CREATE VIEW current_items AS SELECT title FROM original_items;
    """

  /// Points `current_items`, from ``currentItemsViewSchema``, at `alternate_items`.
  let currentItemsViewRedefinition = """
    DROP VIEW current_items;
    CREATE VIEW current_items AS SELECT title FROM alternate_items;
    """

  // MARK: - A database that announces its own commits

  /// A database whose commits the test announces to its observers, rather than SQLite.
  ///
  /// Every write through it is announced once it has committed, as a database that learns of
  /// commits after the fact would, rather than inside the transaction. ``announceCommit(region:
  /// origin:activeWriterBarrier:)`` announces one that never happened, so a test can raise
  /// invalidations while an observation is in whatever state it arranged. It also counts the
  /// observers registered on it, which is the only way to tell how many subscriptions a group of
  /// observations took out.
  final class AnnouncingTestDatabase: OrbitObservableDatabase {
    let defaultIdentifier: OrbitDatabaseIdentifier

    private let base: SQLiteQueue
    private let observers = OrbitDatabaseTransactionObservers()
    private let subscriptions = TestCounter()

    /// How many observers have been registered, whether or not they are still registered.
    var subscriptionCount: Int { self.subscriptions.value }

    init(_ base: SQLiteQueue) {
      self.base = base
      self.defaultIdentifier = base.defaultIdentifier
    }

    func read<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) async throws -> Result {
      try await self.base.read(body)
    }

    func readBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) throws -> Result {
      try self.base.readBlocking(body)
    }

    func readWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) async throws -> Result {
      try await self.base.readWithoutTransaction(body)
    }

    func readWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) throws -> Result {
      try self.base.readWithoutTransactionBlocking(body)
    }

    func write<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) async throws -> Result {
      let (result, region) = try await self.base.write { transaction in
        try transaction.recordingDatabaseRegion(body)
      }
      self.announceCommit(region: region)
      return result
    }

    func writeBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result {
      let (result, region) = try self.base.writeBlocking { transaction in
        try transaction.recordingDatabaseRegion(body)
      }
      self.announceCommit(region: region)
      return result
    }

    func writeWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) async throws -> Result {
      try await self.base.writeWithoutTransaction(body)
    }

    func writeWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) throws -> Result {
      try self.base.writeWithoutTransactionBlocking(body)
    }

    func subscribe(
      transactionObserver: any OrbitDatabaseTransactionObserver,
      region: OrbitDatabaseRegion
    ) throws -> OrbitRegionSubscription {
      self.subscriptions.increment()
      return self.observers.subscribe(transactionObserver, region: region)
    }

    /// Tells every observer that a transaction changed `region` and committed.
    func announceCommit(
      region: OrbitDatabaseRegion,
      origin: OrbitDatabaseTransactionOrigin = .local,
      activeWriterBarrier: SQLitePoolWriterBarrier? = nil
    ) {
      self.observers.didChange(in: region)
      self.observers.didCommit(
        origin: origin,
        region: region,
        activeWriterBarrier: activeWriterBarrier
      )
    }
  }

  // MARK: - The process-wide default database

  /// Runs `body` with `database` as the process-wide default, and puts back whatever was the
  /// default before once `body` returns.
  ///
  /// Anything that reads the default while `body` runs, in any task, sees `database`, so a suite
  /// that calls this must be serialized.
  func withProcessDefaultDatabase<Result>(
    _ database: (any OrbitObservableDatabase)?,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Result
  ) async throws -> Result {
    let previous = OrbitDefaultDatabase.currentIfConfigured
    OrbitDefaultDatabase.set(database)
    defer { OrbitDefaultDatabase.set(previous) }
    return try await body()
  }
#endif
