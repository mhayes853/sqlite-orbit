#if canImport(Foundation) && canImport(Dispatch)
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
      try translate { try native.migrateBlocking(writer.orbitDatabase, upTo: target) }
    }

    public func migrate(_ writer: any DatabaseWriter, upTo target: String? = nil) async throws {
      try await translate { try await native.migrate(writer.orbitDatabase, upTo: target) }
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
  }

#endif
