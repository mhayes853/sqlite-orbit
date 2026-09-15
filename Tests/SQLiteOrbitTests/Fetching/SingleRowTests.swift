#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SingleRowTests {
    @Test
    func anEmptyTableReadsItsDefaultWithoutInsertingIt() async throws {
      let database = try await settingsDatabase()

      @SingleRow(Settings.self, database: database) var settings

      #expect(settings == .defaultValue)
      #expect(!$settings.isLoading)
      #expect($settings.loadError == nil)
      let count = try await database.read { try $0.fetchCount(Settings.all) }
      #expect(count == 0)
    }

    @Test
    func updatingAnEmptyTableInsertsAndObservesTheSingleton() async throws {
      let database = try await settingsDatabase()

      @SingleRow(Settings.self, database: database) var settings

      let previousTheme = try await $settings.update { settings in
        let previousTheme = settings.theme
        settings.theme = "dark"
        settings.launchCount += 1
        return previousTheme
      }

      #expect(previousTheme == "system")
      try await waitUntil { settings.theme == "dark" && settings.launchCount == 1 }
      let persisted = try await database.read { transaction in
        try transaction.find(Settings.all, key: 0)
      }
      #expect(persisted == Settings(id: 0, theme: "dark", launchCount: 1))
      #expect(!$settings.isSaving)
      #expect($settings.saveError == nil)
    }

    @Test
    func saveReplacesTheSingleton() async throws {
      let database = try await settingsDatabase()

      @SingleRow(Settings.self, database: database) var settings
      try await $settings.save(Settings(id: 0, theme: "light", launchCount: 4))

      try await waitUntil { settings.theme == "light" && settings.launchCount == 4 }
    }

    @Test
    func deletingThePersistedSingletonRestoresTheDefault() async throws {
      let database = try await settingsDatabase()

      @SingleRow(Settings.self, database: database) var settings
      try await $settings.save(Settings(id: 0, theme: "dark", launchCount: 1))
      try await waitUntil { settings.theme == "dark" }

      try await database.write { transaction in
        try transaction.execute(Settings.find(0).delete())
      }

      try await waitUntil { settings == .defaultValue }
    }

    @Test
    func aDifferentPrimaryKeyIsRejectedAndReported() async throws {
      let database = try await settingsDatabase(enforceSingleton: false)

      @SingleRow(Settings.self, database: database) var settings

      await #expect(throws: OrbitRowIdentityMismatchError.self) {
        try await $settings.save(Settings(id: 1, theme: "dark", launchCount: 0))
      }
      #expect($settings.saveError is OrbitRowIdentityMismatchError)
      let count = try await database.read { try $0.fetchCount(Settings.all) }
      #expect(count == 0)
    }

    @Test
    func updateReadsTheLatestRowInsideItsWriteTransaction() async throws {
      let database = try await settingsDatabase()

      @SingleRow(Settings.self, database: database) var settings
      _ = settings
      try await database.write { transaction in
        try transaction.execute(
          Settings.upsert { Settings.Draft(Settings(id: 0, theme: "dark", launchCount: 7)) }
        )
      }

      try await $settings.update { $0.launchCount += 1 }

      let persisted = try await database.read { transaction in
        try transaction.find(Settings.all, key: 0)
      }
      #expect(persisted == Settings(id: 0, theme: "dark", launchCount: 8))
    }
  }

  private func settingsDatabase(
    enforceSingleton: Bool = true
  ) async throws -> OrbitDatabase<SQLiteQueue> {
    let database = try inMemoryDatabase()
    let constraint = enforceSingleton ? " CHECK (id = 0)" : ""
    try await database.write { transaction in
      try transaction.execute(
        """
        CREATE TABLE settings (
          id INTEGER PRIMARY KEY\(constraint),
          theme TEXT NOT NULL,
          launchCount INTEGER NOT NULL
        )
        """
      )
    }
    return database
  }

  @Table("settings")
  private struct Settings: Equatable, Sendable, SingleRowTable {
    let id: Int
    var theme: String
    var launchCount: Int

    static let defaultValue = Settings(id: 0, theme: "system", launchCount: 0)
  }
#endif
