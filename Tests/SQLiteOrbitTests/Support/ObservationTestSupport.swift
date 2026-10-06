#if BuiltInSQLite
  #if StructuredQueries
    import StructuredQueriesSQLite
  #endif

  import Foundation
  import SQLiteOrbit

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
        try transaction.execute("INSERT INTO items (id) VALUES (\(id))")
      }
    }
  }

  /// Inserts a row into `items` for each of `ids`, in one write transaction, blocking the calling
  /// thread.
  func insertItemsBlocking(_ ids: Int..., into database: some OrbitDatabaseWriter) throws {
    try database.writeBlocking { transaction in
      for id in ids {
        try transaction.execute("INSERT INTO items (id) VALUES (\(id))")
      }
    }
  }

  /// The number of rows in `items`, as raw SQL.
  let itemCountSQL: SQL = "SELECT count(*) FROM items"

  #if StructuredQueries
    /// The number of rows in `items`, as a fetch reads it.
    let itemCountQuery = #sql("SELECT count(*) FROM items", as: Int.self)
  #endif

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
  /// origin:)`` announces one that never happened, so a test can raise
  /// invalidations while an observation is in whatever state it arranged. It also counts the
  /// observers registered on it, which is the only way to tell how many subscriptions a group of
  /// observations took out.
  // This provider deliberately compiles against an ordinary import, just like a custom driver.
  final class AnnouncingTestDatabase: OrbitDatabaseWriter, OrbitObservableDatabase,
    @unchecked Sendable
  {
    let defaultIdentifier: OrbitDatabaseIdentifier

    private let base: SQLiteQueue
    private let lock = NSLock()
    private var observers: [UUID: any OrbitDatabaseTransactionObserver] = [:]
    private var subscriptions = 0
    private var activeWriters: (any OrbitDatabaseWriterBarrier)?

    /// How many observers have been registered, whether or not they are still registered.
    var subscriptionCount: Int { lock.withLock { subscriptions } }

    init(_ base: SQLiteQueue) {
      self.base = base
      self.defaultIdentifier = base.defaultIdentifier
    }

    func captureActiveWriters() -> (any OrbitDatabaseWriterBarrier)? {
      lock.withLock { activeWriters }
    }

    func setActiveWriters(_ barrier: (any OrbitDatabaseWriterBarrier)?) {
      lock.withLock { activeWriters = barrier }
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
      let recorder = OrbitDatabaseRegionRecorder()
      let result = try await self.base.write { transaction in
        try transaction.withObservation(recorder) { try body(transaction) }
      }
      self.announceCommit(region: recorder.changedRegion)
      return result
    }

    func writeBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result {
      let recorder = OrbitDatabaseRegionRecorder()
      let result = try self.base.writeBlocking { transaction in
        try transaction.withObservation(recorder) { try body(transaction) }
      }
      self.announceCommit(region: recorder.changedRegion)
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
      let id = UUID()
      lock.withLock {
        subscriptions += 1
        observers[id] = transactionObserver
      }
      // Like a local driver, report every commit regardless of the advertised region.
      return OrbitRegionSubscription(region: region) { [weak self] in
        guard let self else { return }
        _ = self.lock.withLock { self.observers.removeValue(forKey: id) }
      }
    }

    /// Tells every observer that a transaction changed `region` and committed.
    func announceCommit(
      region: OrbitDatabaseRegion,
      origin: OrbitDatabaseTransactionOrigin = .local
    ) {
      let callbacks = lock.withLock { Array(observers.values) }
      for observer in callbacks { observer.databaseDidChange(in: region) }
      let commit = OrbitDatabaseCommit(origin: origin, region: region)
      for observer in callbacks { observer.databaseDidCommit(commit) }
    }
  }
#endif
