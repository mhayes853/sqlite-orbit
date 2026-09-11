import Foundation
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
/// register, which is what an older build of the application sees after a newer one has migrated
/// the database, is tolerated unless ``eraseDatabaseOnSchemaChange`` is on;
/// ``hasBeenSuperseded(_:)`` detects it.
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
    ///
    /// The check needs a library whose ``SQLiteLibrary/isForeignKeyCheckAvailable`` is `true`. On
    /// one without it, such as Turso, a migration that would be checked fails with
    /// ``SQLiteFeatureUnavailableError`` before it runs, without taking the write lock. Register it
    /// as ``ForeignKeyChecks/immediate`` there, which Turso enforces statement by statement, or
    /// skip the check by setting ``OrbitDatabaseMigrator/defersForeignKeyChecks`` to `false` first.
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
  /// foreign keys refer to nothing, and nothing reports them. On a library that cannot check at
  /// all, such as Turso, a deferred migration registered while this is `true` fails with
  /// ``SQLiteFeatureUnavailableError`` before it runs.
  ///
  /// ```swift
  /// var migrator = OrbitDatabaseMigrator()
  /// migrator.registerMigration("Create lists", migrate: createLists)
  /// migrator.defersForeignKeyChecks = false
  /// migrator.registerMigration("Rebuild reminders", migrate: rebuildReminders)
  /// ```
  public var defersForeignKeyChecks = true

  /// A boolean value indicating whether the migrator recreates the whole database from scratch if
  /// it detects a change in the definition of migrations.
  ///
  /// - Warning: This flag can destroy your precious users' data!
  ///
  /// When true, the database migrator wipes out the full database content, and runs all migrations
  /// from the start, if one of those conditions is met:
  ///
  /// - A migration has been removed, or renamed.
  /// - A schema change is detected. A schema change is any difference in the `sqlite_master`
  ///   table, which contains the SQL used to create database tables, indexes, triggers, and views.
  ///
  /// This flag is useful during application development: you are still designing migrations, and
  /// the schema changes often.
  ///
  /// It is recommended to not ship it in the distributed application, in order to avoid undesired
  /// data loss. Use the `DEBUG` compilation condition:
  ///
  /// ```swift
  /// var migrator = OrbitDatabaseMigrator()
  /// #if DEBUG
  /// // Speed up development by nuking the database when migrations change
  /// migrator.eraseDatabaseOnSchemaChange = true
  /// #endif
  /// ```
  ///
  /// Every process that opens the database must register the same migrations while this flag is
  /// on; a process running an older build treats newer migrations as removed and erases the
  /// database.
  ///
  /// Whether the database needs erasing is decided before the write lock is taken, so a database
  /// whose migrations have not changed is still neither locked nor announced to other processes.
  /// The erase itself is one write transaction, which checks again under the lock, drops every
  /// table, index, view, and trigger with foreign keys off, and resets `user_version` to 0.
  /// Observers, and other processes, see it as a change to the whole database, as they see any
  /// other schema change.
  ///
  /// See also ``hasSchemaChanges(_:)``.
  public var eraseDatabaseOnSchemaChange = false

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
  ///   ``SQLiteFeatureUnavailableError`` when one is to be checked on a library that cannot check
  ///   foreign keys, whatever a migration throws, a ``SQLiteError``, or `CancellationError` when
  ///   the task was cancelled.
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
  ///   ``SQLiteFeatureUnavailableError`` when one is to be checked on a library that cannot check
  ///   foreign keys, whatever a migration throws, or a ``SQLiteError``.
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
  ///   ``SQLiteFeatureUnavailableError`` when one is to be checked on a library that cannot check
  ///   foreign keys, whatever a migration throws, or a ``SQLiteError``, whose code is
  ///   `SQLITE_BUSY` when the write lock could not be taken in time.
  public func migrate(
    _ connection: borrowing SQLiteWriteConnection,
    upTo target: String? = nil
  ) throws {
    if eraseDatabaseOnSchemaChange {
      // A target that is not registered is refused before anything is erased, just as it is
      // refused before anything is migrated.
      if let target, !migrations.contains(target) {
        throw OrbitDatabaseMigrationTargetError(target: target, reason: .unregistered)
      }
      // The schema the migrations produce, kept so that checking again under the write lock does
      // not migrate a second temporary database.
      var scratch: ScratchSchema?
      // Read outside a transaction, so an up-to-date database is still neither locked nor
      // announced.
      if try schemaChanges(connection, reusing: &scratch) {
        try erase(connection, reusing: &scratch)
      }
    }
    try runMigrations(connection, upTo: target)
  }

  private func runMigrations(
    _ connection: borrowing SQLiteWriteConnection,
    upTo target: String?
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
    let checksForeignKeys = disablesForeignKeys && migration.foreignKeyChecks == .deferred
    // A build that cannot check would let the migration commit whatever it left dangling. Failing
    // here, with the error the check itself throws, runs none of it and takes no write lock.
    if checksForeignKeys, !connection.sqlite.isForeignKeyCheckAvailable {
      throw SQLiteFeatureUnavailableError(
        libraryName: connection.sqlite.name,
        feature: .foreignKeyCheck
      )
    }
    if disablesForeignKeys {
      // Applied just before the transaction begins.
      connection.isForeignKeysEnabled = false
    }
    // Putting the value back only records it, so this runs nothing and cannot fail, and a failed
    // migration's error is rethrown as it is. A deferred migration next turns it off again without
    // a pragma in between; anything else applies it first: an immediate migration's transaction,
    // the caller's next statement, or the end of the access.
    defer { connection.isForeignKeysEnabled = wasForeignKeysEnabled }
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

  private func erase(
    _ connection: borrowing SQLiteWriteConnection,
    reusing scratch: inout ScratchSchema?
  ) throws {
    // Dropping a table other tables refer to with foreign keys on would first delete its rows, and
    // fail on the rows that refer to them.
    let wasForeignKeysEnabled = connection.isForeignKeysEnabled
    connection.isForeignKeysEnabled = false
    // Putting the value back only records it, so this cannot fail.
    defer { connection.isForeignKeysEnabled = wasForeignKeysEnabled }
    try connection.transaction { transaction in
      // Another process may have migrated or erased the database since the first check.
      guard try schemaChanges(transaction, reusing: &scratch) else { return }
      // Dropping a table also drops its indexes and triggers, and a virtual table its shadow
      // tables, so the schema is read again after each drop rather than once.
      while let (type, name) = try firstDroppableObject(in: transaction) {
        try transaction.execute(SQLQueryExpression("DROP \(raw: type) \(quote: name)"))
      }
      try transaction.execute("PRAGMA user_version = 0")
    }
  }

  private func firstDroppableObject(
    in transaction: borrowing SQLiteWriteTransaction
  ) throws -> (type: String, name: String)? {
    // The table of applied migrations is dropped with the rest, and the migrations create it
    // again.
    var cursor = try transaction.rowCursor(
      SQLQueryExpression(
        "SELECT type, name FROM sqlite_schema WHERE \(Self.userObjects) LIMIT 1"
      )
    )
    guard var row = try cursor.next() else { return nil }
    return (try row.decode(String.self), try row.decode(String.self))
  }

  // MARK: - Detecting schema changes

  /// Returns a boolean value indicating whether the migrator detects a change in the definition of
  /// migrations.
  ///
  /// The result is true if one of those conditions is met:
  ///
  /// - A migration has been removed, or renamed.
  /// - There exists any difference in the `sqlite_master` table, which contains the SQL used to
  ///   create database tables, indexes, triggers, and views.
  ///
  /// This method supports the ``eraseDatabaseOnSchemaChange`` option. When
  /// `eraseDatabaseOnSchemaChange` does not exactly fit your needs, you can implement it manually
  /// as below:
  ///
  /// ```swift
  /// #if DEBUG
  /// // Speed up development by starting over when migrations change
  /// if try await database.read(migrator.hasSchemaChanges) {
  ///   // Keep the old database to look into, and open a new one in its place
  ///   database = try archiveAndReplace(database)
  /// }
  /// #endif
  /// try await migrator.migrate(database)
  /// ```
  ///
  /// The schema is compared with that of a temporary database, opened with the same
  /// ``SQLiteTransaction/configuration``, that the registered migrations are applied to up to the
  /// last one this database has applied. The objects SQLite and Turso keep for themselves, and the
  /// table of applied migrations, are left out of the comparison. A database no migration has
  /// been applied to has nothing to compare, and has no schema changes. On a connection outside a
  /// transaction, the applied migrations and the schema are read in separate statements, so
  /// another connection may commit in between; read them in a transaction for an answer that
  /// holds for a single state of the database.
  ///
  /// - Parameter transaction: A read or write transaction, or a connection.
  /// - Returns: `true` when a migration the database has applied is no longer registered, or when
  ///   the database's schema differs from the one the registered migrations produce.
  /// - Throws: Whatever a migration throws, ``OrbitDatabaseForeignKeyViolationError`` when a
  ///   deferred migration leaves violations in the temporary database,
  ///   ``SQLiteFeatureUnavailableError`` when one is to be checked on a library that cannot check
  ///   foreign keys, or a ``SQLiteError`` when either database cannot be read or the temporary one
  ///   cannot be created or migrated.
  public func hasSchemaChanges<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> Bool
  where Transaction: SQLiteTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    var scratch: ScratchSchema?
    return try schemaChanges(transaction, reusing: &scratch)
  }

  private func schemaChanges<Transaction>(
    _ transaction: borrowing Transaction,
    reusing scratch: inout ScratchSchema?
  ) throws -> Bool
  where Transaction: SQLiteTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    let applied = try appliedIdentifiers(transaction)
    guard applied.isSubset(of: migrations) else { return true }
    guard let lastApplied = migrations.last(where: applied.contains) else { return false }
    // Migrating up to the last applied migration also runs any registered before it that the
    // database has not applied, so those count as a change as well, as they do for GRDB.
    let expected: Set<SchemaObject>
    if let scratch, scratch.lastApplied == lastApplied {
      expected = scratch.objects
    } else {
      expected = try migratedSchema(upTo: lastApplied, configuration: transaction.configuration)
      scratch = ScratchSchema(lastApplied: lastApplied, objects: expected)
    }
    return try schema(of: transaction) != expected
  }

  private func migratedSchema(
    upTo target: String,
    configuration: SQLiteConfiguration
  ) throws -> Set<SchemaObject> {
    // A named file rather than a temporary database SQLite names itself: GRDB found those do not
    // accept every setup a named file does, in its issue #931, and not every build supports them.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SQLiteOrbit-migrator-\(UUID().uuidString).sqlite"
    )
    defer {
      // The answer is known by now, and a temporary file left behind is no reason to fail a
      // migration over.
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    // The connection has closed by the time this returns, before its files are deleted.
    return try migratedSchema(at: url, upTo: target, configuration: configuration)
  }

  private func migratedSchema(
    at url: URL,
    upTo target: String,
    configuration: SQLiteConfiguration
  ) throws -> Set<SchemaObject> {
    // The same build, key, functions, collations, and setups, so the migrations run as they ran
    // on the database, and whatever data they seed is encrypted at rest as it is there. Nothing
    // observes it, and it runs on the calling thread: each of its accesses binds its library to
    // the thread and puts back the binding of the access this runs inside once it ends.
    let handle = try SQLiteHandle.open(
      path: .file(url),
      flags: [.readWrite, .create, .noMutex],
      configuration: configuration
    )
    return try handle.writeWithoutTransaction { connection in
      try runMigrations(connection, upTo: target)
      return try schema(of: connection)
    }
  }

  private func schema<Transaction>(
    of transaction: borrowing Transaction
  ) throws -> Set<SchemaObject>
  where Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
    // GRDB leaves out `pragma_` names as well, which SQLite's table-valued pragmas are called by.
    // The table of applied migrations is the migrator's own, compared through its identifiers
    // instead, and one GRDB created is spelled differently from one this migrator creates.
    var objects: Set<SchemaObject> = []
    var cursor = try transaction.rowCursor(
      SQLQueryExpression(
        """
        SELECT type, name, tbl_name, sql FROM sqlite_schema
        WHERE \(Self.userObjects) AND name NOT LIKE 'pragma\\_%' ESCAPE '\\'
          AND name <> \(bind: tableName) COLLATE NOCASE
        """
      )
    )
    while var row = try cursor.next() {
      objects.insert(
        SchemaObject(
          type: try row.decode(String.self),
          name: try row.decode(String.self),
          tableName: try row.decode(String.self),
          sql: try row.decode(String?.self)
        )
      )
    }
    return objects
  }

  // Everything but what SQLite and Turso keep for themselves, which neither lets be dropped:
  // `sqlite_sequence` and automatic indexes, say, or Turso's sequences for `AUTOINCREMENT` and its
  // MVCC metadata. `_` matches any character in a `LIKE` pattern, so it is escaped to match only
  // itself.
  private static let userObjects: QueryFragment = """
    name NOT LIKE 'sqlite\\_%' ESCAPE '\\' \
    AND name NOT LIKE '\\_\\_turso\\_internal\\_%' ESCAPE '\\'
    """

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

// The schema the registered migrations produce up to the last one a database has applied, kept so
// that the check made again under the write lock reuses it rather than migrating a second
// temporary database.
private struct ScratchSchema {
  let lastApplied: String
  let objects: Set<SchemaObject>
}

// A row of `sqlite_schema`.
private struct SchemaObject: Hashable {
  let type: String
  let name: String
  let tableName: String
  let sql: String?
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
