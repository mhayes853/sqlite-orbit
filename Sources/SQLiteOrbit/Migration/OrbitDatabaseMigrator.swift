import StructuredQueries

/// Applies a database's schema migrations in order, each exactly once.
///
/// Register every migration the application has shipped, oldest first, and call
/// ``migrate(_:upTo:)`` when the database opens. Each pending migration runs in a write
/// transaction of its own, which also records its identifier in a table of applied migrations, so
/// a run that stops part way resumes where it stopped and a database that is up to date is left
/// alone. A migration that has shipped must never change afterwards; register a new one instead.
///
/// ```swift
/// var migrator = OrbitDatabaseMigrator()
/// migrator.registerMigration("Create reminders") { transaction in
///   try transaction.execute(
///     "CREATE TABLE reminders (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
///   )
/// }
/// migrator.registerMigration("Add completion") { transaction in
///   try transaction.execute(
///     "ALTER TABLE reminders ADD COLUMN isCompleted INTEGER NOT NULL DEFAULT 0"
///   )
/// }
///
/// let database = try OrbitDatabase(path: databasePath)
/// try await migrator.migrate(database)
/// ```
///
/// Several processes may migrate the same database at once. Each migration's transaction checks
/// again whether another process has applied it in the meantime, and a transaction that finds the
/// database busy is retried a few times. An applied migration this migrator does not register is
/// tolerated, which is what an older build of the application sees after a newer one has migrated
/// the database; ``hasBeenSuperseded(in:)`` detects it.
///
/// The applied migrations are kept in a table named `orbit_migrations` by default, laid out as
/// GRDB lays out its own, so `OrbitDatabaseMigrator(tableName: "grdb_migrations")` continues the
/// history of a database that GRDB's `DatabaseMigrator` has migrated.
public struct OrbitDatabaseMigrator: Sendable {
  /// When the foreign keys of a migration's changes are checked.
  ///
  /// ```swift
  /// migrator.registerMigration("Add lists", foreignKeyChecks: .immediate) { transaction in
  ///   try transaction.execute("CREATE TABLE lists (id INTEGER PRIMARY KEY)")
  /// }
  /// ```
  public enum ForeignKeyChecks: Hashable, Sendable {
    /// Foreign keys are turned off while the migration runs, and the whole database is checked for
    /// violations just before it commits.
    ///
    /// This is what lets a migration rebuild a table other tables refer to, following SQLite's
    /// procedure for schema changes `ALTER TABLE` cannot make: dropping the old table with foreign
    /// keys on would cascade its deletion to every row that refers to it.
    case deferred

    /// Foreign keys are enforced as the connection is configured to enforce them, statement by
    /// statement.
    case immediate
  }

  /// How long a migration waits for a lock another connection holds.
  ///
  /// ```swift
  /// migrator.busyTimeout = .limit(.seconds(30))
  /// ```
  public enum BusyTimeout: Hashable, Sendable {
    /// Waits as long as the connection's ``SQLiteConfiguration/busyTimeout`` allows.
    case configured

    /// Waits up to the given duration, counted in whole milliseconds.
    case limit(Duration)

    /// Waits for as long as it takes.
    case unlimited
  }

  /// How long each migration waits for a lock another connection holds.
  ///
  /// A migration's transaction is retried a few times when it still finds the database busy. The
  /// connection's own busy timeout is restored once migrating is done.
  public var busyTimeout = BusyTimeout.configured

  private let tableName: String
  private var migrations: [Migration] = []
  private var defersForeignKeyChecks = true

  // A transaction that finds the database busy rolls back, so trying it again is safe. A few more
  // tries cover a writer that keeps winning the lock, without spinning on one that holds it for
  // good.
  private static let busyRetryLimit = 3

  /// Creates a migrator with no migrations registered.
  ///
  /// ```swift
  /// var migrator = OrbitDatabaseMigrator()
  /// ```
  ///
  /// - Parameter tableName: The table that records which migrations have been applied. It is
  ///   created by the first migration to run. Pass `"grdb_migrations"` to continue a history
  ///   recorded by GRDB.
  public init(tableName: String = "orbit_migrations") {
    self.tableName = tableName
  }

  /// Registers a migration, to run after every migration registered before it.
  ///
  /// ```swift
  /// migrator.registerMigration("Create reminders") { transaction in
  ///   try transaction.execute(
  ///     "CREATE TABLE reminders (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
  ///   )
  /// }
  /// ```
  ///
  /// - Important: Registering two migrations with the same identifier is a programming error and
  ///   stops the process.
  ///
  /// - Parameters:
  ///   - identifier: The name the migration is recorded under once it is applied. It must never
  ///     change once the migration has shipped.
  ///   - foreignKeyChecks: When the foreign keys of the migration's changes are checked.
  ///   - migrate: Makes the migration's changes in the transaction it is given. Throwing rolls the
  ///     migration back and fails ``migrate(_:upTo:)`` with the same error.
  public mutating func registerMigration(
    _ identifier: String,
    foreignKeyChecks: ForeignKeyChecks = .deferred,
    migrate: @escaping @Sendable (borrowing SQLiteWriteTransaction) throws -> Void
  ) {
    precondition(
      !migrations.contains { $0.identifier == identifier },
      """
      A migration named "\(identifier)" is already registered. Each migration needs an identifier \
      of its own, since the identifier is what records that it has been applied.
      """
    )
    let checks: Migration.ForeignKeyChecks =
      switch foreignKeyChecks {
      case .deferred: defersForeignKeyChecks ? .deferred : .disabled
      case .immediate: .immediate
      }
    migrations.append(Migration(identifier: identifier, foreignKeyChecks: checks, migrate: migrate))
  }

  /// Returns a migrator whose later deferred migrations skip their foreign key check.
  ///
  /// A migration registered on the returned migrator with ``ForeignKeyChecks/deferred`` still runs
  /// with foreign keys off, but is not checked for violations before it commits. Checking reads
  /// every table that has a foreign key, which a large database can take a while over. Skipping it
  /// trades that time for the guarantee: a migration can then leave rows whose foreign keys refer
  /// to nothing, and nothing reports them. Migrations registered before the call keep their check.
  ///
  /// ```swift
  /// var migrator = OrbitDatabaseMigrator()
  /// migrator.registerMigration("Create lists", migrate: createLists)
  /// migrator = migrator.disablingDeferredForeignKeyChecks()
  /// migrator.registerMigration("Rebuild reminders", migrate: rebuildReminders)
  /// ```
  ///
  /// - Returns: A copy of this migrator that registers deferred migrations without a check.
  public func disablingDeferredForeignKeyChecks() -> Self {
    var migrator = self
    migrator.defersForeignKeyChecks = false
    return migrator
  }

  // MARK: - Migrating

  /// Applies every registered migration the database has not applied yet, in registration order.
  ///
  /// Whether anything is pending is decided before the write lock is taken, so a database that is
  /// already up to date is neither locked nor announced to other processes. Each pending
  /// migration then runs in its own write transaction, so a failure leaves the migrations before
  /// it applied. Cancelling the task stops the run at the migration that is running, which is
  /// rolled back.
  ///
  /// ```swift
  /// try await migrator.migrate(database)
  /// ```
  ///
  /// - Parameters:
  ///   - writer: The database to migrate.
  ///   - target: The identifier of the last migration to apply, or `nil` to apply every
  ///     registered migration. Migrating up to a target is how a test checks one migration
  ///     against the data the ones before it left.
  /// - Throws: ``OrbitDatabaseMigrationTargetError`` when `target` cannot be migrated up to,
  ///   ``OrbitDatabaseForeignKeyViolationError`` when a deferred migration leaves violations,
  ///   whatever a migration throws, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled.
  public func migrate(
    _ writer: some OrbitDatabaseWriter,
    upTo target: String? = nil
  ) async throws {
    try await writer.writeWithoutTransaction { connection in
      try self.migratePending(on: connection, upTo: target)
    }
  }

  /// Applies every registered migration the database has not applied yet, blocking the calling
  /// thread until it finishes.
  ///
  /// - Important: Never call this from a task. Blocking a thread of Swift's cooperative pool
  ///   starves the machinery the rest of the database runs on.
  ///
  /// ```swift
  /// try migrator.migrateBlocking(database)
  /// ```
  ///
  /// - Parameters:
  ///   - writer: The database to migrate.
  ///   - target: The identifier of the last migration to apply, or `nil` to apply every
  ///     registered migration.
  /// - Throws: ``OrbitDatabaseMigrationTargetError`` when `target` cannot be migrated up to,
  ///   ``OrbitDatabaseForeignKeyViolationError`` when a deferred migration leaves violations,
  ///   whatever a migration throws, or a ``SQLiteError``.
  public func migrateBlocking(
    _ writer: some OrbitDatabaseWriter,
    upTo target: String? = nil
  ) throws {
    try writer.writeWithoutTransactionBlocking { connection in
      try self.migratePending(on: connection, upTo: target)
    }
  }

  private func migratePending(
    on connection: borrowing SQLiteWriteConnection,
    upTo target: String?
  ) throws {
    // Reading outside a transaction takes no write lock, which is what lets the launch of an
    // application whose database is up to date leave it alone.
    let pending = try pendingMigrations(applied: appliedIdentifiers(in: connection), upTo: target)
    guard !pending.isEmpty else { return }

    let configuredBusyTimeout = try overrideBusyTimeout(on: connection)
    defer {
      if let configuredBusyTimeout {
        try? connection.execute("PRAGMA busy_timeout = \(configuredBusyTimeout)")
      }
    }
    let foreignKeys = try connection.fetchOne(
      SQLQueryExpression("PRAGMA foreign_keys", as: Int.self)
    )
    let isForeignKeysEnabled = (foreignKeys ?? 0) != 0
    for migration in pending {
      try apply(migration, on: connection, isForeignKeysEnabled: isForeignKeysEnabled)
    }
  }

  private func pendingMigrations(
    applied: Set<String>,
    upTo target: String?
  ) throws -> [Migration] {
    var candidates = migrations[...]
    if let target {
      guard let index = migrations.firstIndex(where: { $0.identifier == target }) else {
        throw OrbitDatabaseMigrationTargetError(target: target, reason: .unregistered)
      }
      if let later = migrations[(index + 1)...].first(where: { applied.contains($0.identifier) }) {
        throw OrbitDatabaseMigrationTargetError(
          target: target,
          reason: .migratedBeyond(later.identifier)
        )
      }
      candidates = migrations[...index]
    }
    return candidates.filter { !applied.contains($0.identifier) }
  }

  private func overrideBusyTimeout(on connection: borrowing SQLiteWriteConnection) throws -> Int? {
    let milliseconds: Int32
    switch busyTimeout {
    case .configured: return nil
    case .limit(let duration): milliseconds = SQLiteBusyTimeout.limit(duration).milliseconds
    case .unlimited: milliseconds = .max
    }
    let configured =
      try connection.fetchOne(SQLQueryExpression("PRAGMA busy_timeout", as: Int.self)) ?? 0
    try connection.execute("PRAGMA busy_timeout = \(milliseconds)")
    return configured
  }

  private func apply(
    _ migration: Migration,
    on connection: borrowing SQLiteWriteConnection,
    isForeignKeysEnabled: Bool
  ) throws {
    // SQLite ignores `PRAGMA foreign_keys` inside a transaction, which is why a migration runs on
    // a connection outside one and opens its own. With foreign keys already off there is nothing
    // to defer, and nothing a check would be guarding.
    let disablesForeignKeys = isForeignKeysEnabled && migration.foreignKeyChecks != .immediate
    if disablesForeignKeys {
      try connection.execute("PRAGMA foreign_keys = 0")
    }
    defer {
      if disablesForeignKeys {
        try? connection.execute("PRAGMA foreign_keys = 1")
      }
    }
    let checksForeignKeys = disablesForeignKeys && migration.foreignKeyChecks == .deferred

    var retries = 0
    while true {
      do {
        try connection.transaction { transaction in
          try record(migration, in: transaction, checkingForeignKeys: checksForeignKeys)
        }
        return
      } catch let error as SQLiteError
        where error.primaryCode == .busy && retries < Self.busyRetryLimit
      {
        // The transaction rolled back, and the next one checks again whether the migration is
        // still pending, so another process that got there first is not raced a second time.
        retries += 1
      }
    }
  }

  private func record(
    _ migration: Migration,
    in transaction: borrowing SQLiteWriteTransaction,
    checkingForeignKeys: Bool
  ) throws {
    if try hasMigrationsTable(in: transaction) {
      // Another process may have applied the migration since it was found pending. Holding the
      // write lock is what makes this answer final.
      guard try !isApplied(migration.identifier, in: transaction) else { return }
    } else {
      // Creating the table only when it is missing matters: a schema change is announced as a
      // change to the whole database, and throws away every connection's cached statements.
      try transaction.execute(
        SQLQueryExpression(
          "CREATE TABLE \(quote: tableName) (identifier TEXT NOT NULL PRIMARY KEY)"
        )
      )
    }
    try migration.migrate(transaction)
    if checkingForeignKeys {
      try checkForeignKeys(after: migration, in: transaction)
    }
    try transaction.execute(
      SQLQueryExpression(
        "INSERT INTO \(quote: tableName) (identifier) VALUES (\(bind: migration.identifier))"
      )
    )
  }

  private func checkForeignKeys(
    after migration: Migration,
    in transaction: borrowing SQLiteWriteTransaction
  ) throws {
    var violations: [OrbitDatabaseForeignKeyViolationError.Violation] = []
    var cursor = try transaction.rowCursor(SQLQueryExpression("PRAGMA foreign_key_check"))
    while var row = try cursor.next() {
      violations.append(
        OrbitDatabaseForeignKeyViolationError.Violation(
          table: try row.decode(String.self),
          rowID: try row.decode(Int64?.self),
          parentTable: try row.decode(String.self),
          foreignKeyIndex: try row.decode(Int.self)
        )
      )
    }
    guard violations.isEmpty else {
      throw OrbitDatabaseForeignKeyViolationError(
        migration: migration.identifier,
        violations: violations
      )
    }
  }

  // MARK: - Inspecting

  /// Returns the identifier of every migration the database has applied, including any this
  /// migrator does not register.
  ///
  /// A database no migrator has run on yet has applied nothing.
  ///
  /// ```swift
  /// let applied = try await database.read { try migrator.appliedIdentifiers(in: $0) }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: Every recorded identifier.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func appliedIdentifiers<Transaction>(
    in transaction: borrowing Transaction
  ) throws -> Set<String>
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    // A read cannot create the table, so a missing one is read as nothing applied yet.
    guard try hasMigrationsTable(in: transaction) else { return [] }
    let identifiers = try transaction.fetchAll(
      SQLQueryExpression("SELECT identifier FROM \(quote: tableName)", as: String.self)
    )
    return Set(identifiers)
  }

  /// Returns the registered migrations the database has applied, in registration order.
  ///
  /// ```swift
  /// let applied = try await database.read { try migrator.appliedMigrations(in: $0) }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: The identifiers of the registered migrations that have been applied.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func appliedMigrations<Transaction>(
    in transaction: borrowing Transaction
  ) throws -> [String]
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let applied = try appliedIdentifiers(in: transaction)
    return migrations.map(\.identifier).filter(applied.contains)
  }

  /// Returns the registered migrations the database has applied up to the first one it has not.
  ///
  /// This differs from ``appliedMigrations(in:)`` only when a migration was applied out of order,
  /// which only happens when one is registered between two that have already shipped.
  ///
  /// ```swift
  /// let completed = try await database.read { try migrator.completedMigrations(in: $0) }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: The identifiers of the leading registered migrations that have all been applied.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func completedMigrations<Transaction>(
    in transaction: borrowing Transaction
  ) throws -> [String]
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let applied = try appliedIdentifiers(in: transaction)
    return Array(migrations.map(\.identifier).prefix(while: applied.contains))
  }

  /// Returns whether the database has applied every registered migration.
  ///
  /// ```swift
  /// let isUpToDate = try await database.read { try migrator.hasCompletedMigrations(in: $0) }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: `true` when no registered migration is pending.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func hasCompletedMigrations<Transaction>(
    in transaction: borrowing Transaction
  ) throws -> Bool
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let applied = try appliedIdentifiers(in: transaction)
    return migrations.allSatisfy { applied.contains($0.identifier) }
  }

  /// Returns whether the database has applied a migration this migrator does not register.
  ///
  /// That is what an older build of an application finds after a newer one has migrated the
  /// database, and a sign that the schema may hold more than this build expects.
  ///
  /// ```swift
  /// if try await database.read({ try migrator.hasBeenSuperseded(in: $0) }) {
  ///   showUpdateRequiredAlert()
  /// }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: `true` when an applied migration is not registered here.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func hasBeenSuperseded<Transaction>(
    in transaction: borrowing Transaction
  ) throws -> Bool
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let registered = Set(migrations.map(\.identifier))
    return try !appliedIdentifiers(in: transaction).isSubset(of: registered)
  }

  private func hasMigrationsTable<Transaction>(
    in transaction: borrowing Transaction
  ) throws -> Bool
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    // SQLite resolves table names without regard to case, so the lookup does too.
    let count = try transaction.fetchOne(
      SQLQueryExpression(
        """
        SELECT count(*) FROM sqlite_schema
        WHERE type = 'table' AND name = \(bind: tableName) COLLATE NOCASE
        """,
        as: Int.self
      )
    )
    return (count ?? 0) > 0
  }

  private func isApplied(
    _ identifier: String,
    in transaction: borrowing SQLiteWriteTransaction
  ) throws -> Bool {
    let count = try transaction.fetchOne(
      SQLQueryExpression(
        "SELECT count(*) FROM \(quote: tableName) WHERE identifier = \(bind: identifier)",
        as: Int.self
      )
    )
    return (count ?? 0) > 0
  }
}

private struct Migration: Sendable {
  enum ForeignKeyChecks {
    // Foreign keys off while it runs, then the whole database checked before it commits.
    case deferred
    // Foreign keys off while it runs, and no check: registered after
    // `disablingDeferredForeignKeyChecks()`.
    case disabled
    // Foreign keys as the connection has them.
    case immediate
  }

  let identifier: String
  let foreignKeyChecks: ForeignKeyChecks
  let migrate: @Sendable (borrowing SQLiteWriteTransaction) throws -> Void
}
