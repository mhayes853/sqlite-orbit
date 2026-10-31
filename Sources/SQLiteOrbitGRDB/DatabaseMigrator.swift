#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  public struct DatabaseMigrator: Sendable {
    public typealias ForeignKeyChecks = OrbitDatabaseMigrator.ForeignKeyChecks
    private var native = OrbitDatabaseMigrator.grdb

    public init() {}

    public var migrations: [String] {
      native.migrations
    }

    public var eraseDatabaseOnSchemaChange: Bool {
      get {
        native.eraseDatabaseOnSchemaChange
      }
      set {
        native.eraseDatabaseOnSchemaChange = newValue
      }
    }

    public mutating func registerMigration(
      _ identifier: String,
      foreignKeyChecks: ForeignKeyChecks = .deferred,
      migrate: @escaping @Sendable (Database) throws -> Void
    ) {
      native.registerMigration(identifier, foreignKeyChecks: foreignKeyChecks) { transaction in
        try transaction.withScopedAccess { try migrate(Database($0)) }
      }
    }

    public func disablingDeferredForeignKeyChecks() -> Self {
      var result = self
      result.native = native.disablingDeferredForeignKeyChecks()
      return result
    }

    public func migrate(_ writer: any DatabaseWriter, upTo target: String? = nil) throws {
      try translateMigration {
        try translate { try native.migrateBlocking(writer.orbitDatabase, upTo: target) }
      }
    }

    public func migrate(_ writer: any DatabaseWriter, upTo target: String? = nil) async throws {
      do {
        try await translate { try await native.migrate(writer.orbitDatabase, upTo: target) }
      } catch let error as OrbitDatabaseForeignKeyViolationError {
        throw Self.foreignKeyError(error)
      }
    }

    // GRDB reports foreign key violations found after a migration as SQLITE_CONSTRAINT_FOREIGNKEY.
    private func translateMigration<T>(_ body: () throws -> T) throws -> T {
      do {
        return try body()
      } catch let error as OrbitDatabaseForeignKeyViolationError {
        throw Self.foreignKeyError(error)
      }
    }

    private static func foreignKeyError(_ error: OrbitDatabaseForeignKeyViolationError)
      -> DatabaseError
    {
      DatabaseError(resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY, message: error.description)
    }

    /// Schedules all pending migrations. Success receives the writer connection outside a
    /// transaction, before releasing the writer barrier. The database may not escape completion.
    public func asyncMigrate(
      _ writer: any DatabaseWriter,
      completion: @escaping @Sendable (Result<Database, Error>) -> Void
    ) {
      let completion = DatabaseAccessCompletion(completion)
      Task {
        do {
          try await translate {
            try await writer.orbitDatabase.writeWithoutTransaction { connection in
              try native.migrate(connection)
              connection.withScopedAccess { completion(.success(Database($0))) }
            }
          }
        } catch let error as OrbitDatabaseForeignKeyViolationError {
          completion(.failure(Self.foreignKeyError(error)))
        } catch {
          completion(.failure(error))
        }
      }
    }

    public func appliedIdentifiers(_ db: Database) throws -> Set<String> {
      guard try db.tableExists("grdb_migrations") else {
        return []
      }
      return Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
    }

    public func appliedMigrations(_ db: Database) throws -> [String] {
      let applied = try appliedIdentifiers(db)
      return migrations.filter(applied.contains)
    }

    public func completedMigrations(_ db: Database) throws -> [String] {
      let applied = try appliedIdentifiers(db)
      return Array(migrations.prefix(while: applied.contains))
    }

    public func hasCompletedMigrations(_ db: Database) throws -> Bool {
      try completedMigrations(db) == migrations
    }

    public func hasBeenSuperseded(_ db: Database) throws -> Bool {
      try !appliedIdentifiers(db).isSubset(of: Set(migrations))
    }

    /// Whether the database schema differs from the schema the applied migrations create, or
    /// the database contains unknown migrations.
    ///
    /// Migrations up to the last applied one run in a temporary database file, with the
    /// configuration of `db`, and the user schemas are compared.
    public func hasSchemaChanges(_ db: Database) throws -> Bool {
      let applied = try appliedIdentifiers(db)
      guard applied.isSubset(of: Set(migrations)) else { return true }
      guard let last = migrations.last(where: applied.contains) else { return false }
      var configuration = db.configuration
      configuration.readonly = false
      configuration.label = "GRDB.DatabaseMigrator.temporary"
      let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
      defer {
        for suffix in ["", "-wal", "-shm", "-journal"] {
          try? FileManager.default.removeItem(atPath: path + suffix)
        }
      }
      let temporarySchema: Set<[String?]> = try {
        let temporary = try DatabaseQueue(path: path, configuration: configuration)
        try migrate(temporary, upTo: last)
        return try temporary.read { try userSchema($0) }
      }()
      return try userSchema(db) != temporarySchema
    }

    // The schema objects of the main database, excluding SQLite and GRDB internal tables.
    private func userSchema(_ db: Database) throws -> Set<[String?]> {
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT type, name, tbl_name, sql FROM main.sqlite_master"
      )
      return Set(
        rows.compactMap { row -> [String?]? in
          let name: String = row["name"]
          guard !name.hasPrefix("sqlite_"), !name.hasPrefix("grdb_") else { return nil }
          return [row["type"], name, row["tbl_name"], row["sql"]]
        }
      )
    }
  }

#endif
