import StructuredQueries

/// Applies a database's schema migrations in order, each exactly once.
///
/// Register every migration the application has shipped, oldest first, and call
/// ``migrate(_:upTo:)-(OrbitDatabaseWriter,_)`` when the database opens. Each pending migration
/// runs in a write transaction of its own, which also records its identifier in a table of applied
/// migrations, so a run that stops part way resumes where it stopped and a database that is up to
/// date is left alone. A migration that has shipped must never change afterwards; register a new
/// one instead.
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
/// again whether another process has applied it in the meantime, and waits for the write lock as
/// long as the connection's busy timeout allows. To wait longer, migrate on a connection whose
/// ``SQLiteWriteConnection/busyTimeout`` has been raised, with
/// ``migrate(_:upTo:)-(SQLiteWriteConnection,_)``. An applied migration this migrator does not
/// register is tolerated, which is what an older build of the application sees after a newer one
/// has migrated the database; ``hasBeenSuperseded(_:)`` detects it.
///
/// The applied migrations are kept in a table named `orbit_migrations` by default, laid out as
/// GRDB lays out its own, so ``grdb`` continues the history of a database that GRDB's
/// `DatabaseMigrator` has migrated.
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

    /// Foreign keys are enforced as the connection enforces them when the migration begins,
    /// statement by statement.
    case immediate
  }

  /// Whether deferred migrations registered from now on have the database checked for foreign key
  /// violations before they commit.
  ///
  /// This is read when a migration is registered, not when it runs. Setting it to `false` affects
  /// only the ``ForeignKeyChecks/deferred`` migrations registered afterwards: they still run with
  /// foreign keys off, but skip the check, and migrations registered earlier keep theirs. `false`
  /// does not mean foreign keys are checked statement by statement instead; register a migration
  /// with ``ForeignKeyChecks/immediate`` for that.
  ///
  /// Checking reads every table that has a foreign key, which a large database can take a while
  /// over. Skipping it trades that time for the guarantee: a migration can then leave rows whose
  /// foreign keys refer to nothing, and nothing reports them.
  ///
  /// ```swift
  /// var migrator = OrbitDatabaseMigrator()
  /// migrator.registerMigration("Create lists", migrate: createLists)
  /// migrator.defersForeignKeyChecks = false
  /// migrator.registerMigration("Rebuild reminders", migrate: rebuildReminders)
  /// ```
  public var defersForeignKeyChecks = true

  /// The identifiers of the registered migrations, in the order they were registered.
  ///
  /// ```swift
  /// let latest = migrator.migrations.last
  /// ```
  public var migrations: [String] {
    registeredMigrations.map(\.identifier)
  }

  private let tableName: String
  private var registeredMigrations: [Migration] = []

  /// Creates a migrator with no migrations registered.
  ///
  /// ```swift
  /// var migrator = OrbitDatabaseMigrator()
  /// ```
  ///
  /// - Parameter tableName: The table that records which migrations have been applied. It is
  ///   created by the first migration to run. ``grdb`` is the migrator for a history recorded by
  ///   GRDB.
  public init(tableName: String = "orbit_migrations") {
    self.tableName = tableName
  }

  /// A migrator with no migrations registered that records its history in `grdb_migrations`, the
  /// table GRDB's `DatabaseMigrator` records its own in.
  ///
  /// Register the migrations GRDB applied under the identifiers GRDB knew them by, and the
  /// database carries on from where GRDB left it.
  ///
  /// ```swift
  /// var migrator = OrbitDatabaseMigrator.grdb
  /// migrator.registerMigration("v1") { transaction in
  ///   try transaction.execute("CREATE TABLE reminders (id INTEGER PRIMARY KEY)")
  /// }
  /// ```
  public static var grdb: Self {
    Self(tableName: "grdb_migrations")
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
  ///   - foreignKeyChecks: When the foreign keys of the migration's changes are checked. A
  ///     deferred migration registered while ``defersForeignKeyChecks`` is `false` skips the check.
  ///   - migrate: Makes the migration's changes in the transaction it is given. Throwing rolls the
  ///     migration back and fails the run with the same error.
  public mutating func registerMigration(
    _ identifier: String,
    foreignKeyChecks: ForeignKeyChecks = .deferred,
    migrate: @escaping @Sendable (borrowing SQLiteWriteTransaction) throws -> Void
  ) {
    precondition(
      !registeredMigrations.contains { $0.identifier == identifier },
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
    registeredMigrations.append(
      Migration(identifier: identifier, foreignKeyChecks: checks, migrate: migrate)
    )
  }

  /// Returns a copy of this migrator whose ``defersForeignKeyChecks`` is `false`.
  ///
  /// This is here for compatibility with GRDB's `DatabaseMigrator`, so code written against it
  /// carries over unchanged. Setting ``defersForeignKeyChecks`` does the same without the copy.
  /// This migrator is left as it was.
  ///
  /// ```swift
  /// migrator = migrator.disablingDeferredForeignKeyChecks()
  /// migrator.registerMigration("Rebuild reminders", migrate: rebuildReminders)
  /// ```
  ///
  /// - Returns: A copy whose deferred migrations registered from now on skip their check.
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
      try self.migrate(connection, upTo: target)
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
      try self.migrate(connection, upTo: target)
    }
  }

  /// Applies every registered migration the database has not applied yet, on a connection the
  /// caller already holds.
  ///
  /// This is what the other `migrate` methods run, for when the connection needs setting up
  /// first. Each migration's transaction waits for the write lock as long as the connection's
  /// ``SQLiteWriteConnection/busyTimeout`` allows, and fails with `SQLITE_BUSY` once it runs out,
  /// so raising the timeout is how a launch waits out another process that holds the lock for
  /// long:
  ///
  /// ```swift
  /// try await database.writeWithoutTransaction { connection in
  ///   connection.busyTimeout = .maximum
  ///   try migrator.migrate(connection)
  /// }
  /// ```
  ///
  /// A deferred migration turns ``SQLiteWriteConnection/isForeignKeysEnabled`` off while it runs,
  /// and back to what it was once it ends, whether it committed or failed. Turning it back only
  /// records the value, which takes effect before the connection's next statement, so a
  /// connection used after a failed migration enforces foreign keys as it did before.
  ///
  /// - Important: Calling this inside the connection's own
  ///   ``SQLiteWriteConnection/transaction(_:)`` is a programming error: each migration opens a
  ///   transaction of its own, and transactions do not nest.
  ///
  /// - Parameters:
  ///   - connection: The connection to migrate on.
  ///   - target: The identifier of the last migration to apply, or `nil` to apply every
  ///     registered migration.
  /// - Throws: ``OrbitDatabaseMigrationTargetError`` when `target` cannot be migrated up to,
  ///   ``OrbitDatabaseForeignKeyViolationError`` when a deferred migration leaves violations,
  ///   whatever a migration throws, or a ``SQLiteError``, whose code is `SQLITE_BUSY` when the
  ///   write lock could not be taken in time.
  public func migrate(
    _ connection: borrowing SQLiteWriteConnection,
    upTo target: String? = nil
  ) throws {
    // Reading outside a transaction takes no write lock, which is what lets the launch of an
    // application whose database is up to date leave it alone.
    let pending = try pendingMigrations(applied: appliedIdentifiers(connection), upTo: target)
    for migration in pending {
      try apply(migration, on: connection)
    }
  }

  private func pendingMigrations(
    applied: Set<String>,
    upTo target: String?
  ) throws -> [Migration] {
    var candidates = registeredMigrations[...]
    if let target {
      guard let index = registeredMigrations.firstIndex(where: { $0.identifier == target }) else {
        throw OrbitDatabaseMigrationTargetError(target: target, reason: .unregistered)
      }
      let later = registeredMigrations[(index + 1)...].first { applied.contains($0.identifier) }
      if let later {
        throw OrbitDatabaseMigrationTargetError(
          target: target,
          reason: .migratedBeyond(later.identifier)
        )
      }
      candidates = registeredMigrations[...index]
    }
    return candidates.filter { !applied.contains($0.identifier) }
  }

  private func apply(
    _ migration: Migration,
    on connection: borrowing SQLiteWriteConnection
  ) throws {
    // SQLite ignores a change to foreign keys inside a transaction, which is why a migration runs
    // on a connection outside one and opens its own. With foreign keys already off there is
    // nothing to defer, and nothing a check would be guarding.
    let wasForeignKeysEnabled = connection.isForeignKeysEnabled
    let disablesForeignKeys = wasForeignKeysEnabled && migration.foreignKeyChecks != .immediate
    if disablesForeignKeys {
      // Applied just before the transaction begins.
      connection.isForeignKeysEnabled = false
    }
    // Putting the value back only records it, so this runs nothing and cannot fail, and a failed
    // migration's error is rethrown as it is. A deferred migration next turns it off again without
    // a pragma in between; anything else applies it first: an immediate migration's transaction,
    // the caller's next statement, or the end of the access.
    defer { connection.isForeignKeysEnabled = wasForeignKeysEnabled }
    let checksForeignKeys = disablesForeignKeys && migration.foreignKeyChecks == .deferred
    try connection.transaction { transaction in
      try record(migration, in: transaction, checkingForeignKeys: checksForeignKeys)
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
      let violations = try transaction.foreignKeyViolations()
      guard violations.isEmpty else {
        throw OrbitDatabaseForeignKeyViolationError(
          migration: migration.identifier,
          violations: violations
        )
      }
    }
    try transaction.execute(
      SQLQueryExpression(
        "INSERT INTO \(quote: tableName) (identifier) VALUES (\(bind: migration.identifier))"
      )
    )
  }

  // MARK: - Inspecting

  /// Returns the identifier of every migration the database has applied, including any this
  /// migrator does not register.
  ///
  /// A database no migrator has run on yet has applied nothing.
  ///
  /// ```swift
  /// let applied = try await database.read { try migrator.appliedIdentifiers($0) }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: Every recorded identifier.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func appliedIdentifiers<Transaction>(
    _ transaction: borrowing Transaction
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
  /// let applied = try await database.read { try migrator.appliedMigrations($0) }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: The identifiers of the registered migrations that have been applied.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func appliedMigrations<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> [String]
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let applied = try appliedIdentifiers(transaction)
    return migrations.filter(applied.contains)
  }

  /// Returns the registered migrations the database has applied up to the first one it has not.
  ///
  /// This differs from ``appliedMigrations(_:)`` only when a migration was applied out of order,
  /// which only happens when one is registered between two that have already shipped.
  ///
  /// ```swift
  /// let completed = try await database.read { try migrator.completedMigrations($0) }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: The identifiers of the leading registered migrations that have all been applied.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func completedMigrations<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> [String]
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let applied = try appliedIdentifiers(transaction)
    return Array(migrations.prefix(while: applied.contains))
  }

  /// Returns whether the database has applied every registered migration.
  ///
  /// ```swift
  /// let isUpToDate = try await database.read { try migrator.hasCompletedMigrations($0) }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: `true` when no registered migration is pending.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func hasCompletedMigrations<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> Bool
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let applied = try appliedIdentifiers(transaction)
    return migrations.allSatisfy(applied.contains)
  }

  /// Returns whether the database has applied a migration this migrator does not register.
  ///
  /// That is what an older build of an application finds after a newer one has migrated the
  /// database, and a sign that the schema may hold more than this build expects.
  ///
  /// ```swift
  /// if try await database.read({ try migrator.hasBeenSuperseded($0) }) {
  ///   showUpdateRequiredAlert()
  /// }
  /// ```
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: `true` when an applied migration is not registered here.
  /// - Throws: A ``SQLiteError`` when the table of applied migrations cannot be read.
  public func hasBeenSuperseded<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> Bool
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let registered = Set(migrations)
    return try !appliedIdentifiers(transaction).isSubset(of: registered)
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
    // Foreign keys off while it runs, and no check: registered while `defersForeignKeyChecks` was
    // `false`.
    case disabled
    // Foreign keys as the connection has them.
    case immediate
  }

  let identifier: String
  let foreignKeyChecks: ForeignKeyChecks
  let migrate: @Sendable (borrowing SQLiteWriteTransaction) throws -> Void
}
