#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SingleRowTests {
    @Test
    func savingRemainsTrueUntilAHeldUpdateCompletes() async throws {
      let database = try await settingsDatabase()
      @SingleRow(Settings.self, database: database) var settings
      let property = $settings
      let gate = TestGate()
      defer { gate.open() }
      let update = Task {
        try await property.update { value in
          value.theme = "dark"
          try gate.enter()
        }
      }
      defer { update.cancel() }
      try await gate.waitUntilEntered()
      #expect(property.isSaving)
      gate.open()
      try await update.value
      #expect(!property.isSaving)
      #expect(property.saveError == nil)
      let persisted = try await database.read { try Settings.find(in: $0) }
      var expected = Settings.defaultValue
      expected.theme = "dark"
      #expect(persisted == expected)
      try await property.save(expected)
      #expect(property.saveError == nil)
      #expect(!property.isSaving)
    }

    @Test(arguments: ["mutation", "identity", "constraint"])
    func failedUpdatePreservesDataAndASuccessfulSaveClearsTheError(failure: String) async throws {
      let database = try await settingsDatabase()
      try await database.write { try Settings.defaultValue.save(in: $0) }
      @SingleRow(Settings.self, database: database) var settings
      if failure == "constraint" {
        try await database.write {
          try $0.execute(
            "CREATE TRIGGER reject_update BEFORE UPDATE ON settings BEGIN SELECT RAISE(ABORT, 'refused'); END"
          )
        }
      }
      do {
        try await $settings.update { value in
          value.theme = "dark"
          if failure == "mutation" { throw TestError() }
          if failure == "identity" { value = Settings(id: 1, theme: "changed", launchCount: 0) }
        }
        Issue.record("The update should fail for \(failure)")
      } catch {
        switch failure {
        case "mutation": #expect(error is TestError)
        case "identity": #expect(error is OrbitRowIdentityMismatchError)
        default: #expect((error as? SQLiteError)?.primaryCode == .constraint)
        }
      }
      #expect(!$settings.isSaving)
      #expect($settings.saveError != nil)
      let unchanged = try await database.read { try Settings.find(in: $0) }
      #expect(unchanged == Settings.defaultValue)
      if failure == "constraint" {
        try await database.write { try $0.execute("DROP TRIGGER reject_update") }
      }
      var replacement = Settings.defaultValue
      replacement.theme = "dark"
      try await $settings.save(replacement)
      #expect(!$settings.isSaving)
      #expect($settings.saveError == nil)
      let persisted = try await database.read { try Settings.find(in: $0) }
      #expect(persisted == replacement)
    }

    @Test
    func queryHelpersFindSaveAndUpdateTheSingleton() async throws {
      let database = try await settingsDatabase()

      let initial = try await database.read { try Settings.find(in: $0) }
      #expect(initial == .defaultValue)

      try await database.write { transaction in
        try Settings(id: 0, theme: "dark", launchCount: 2).save(in: transaction)
      }
      let persisted = try await database.read { try Settings.find(in: $0) }
      #expect(persisted == Settings(id: 0, theme: "dark", launchCount: 2))

      let previousTheme = try await database.write { transaction in
        try Settings.update(in: transaction) { settings in
          let previousTheme = settings.theme
          settings.theme = "light"
          settings.launchCount += 1
          return previousTheme
        }
      }
      #expect(previousTheme == "dark")
      let updated = try await database.read { try Settings.find(in: $0) }
      #expect(updated == Settings(id: 0, theme: "light", launchCount: 3))
    }

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
    func saveReplacesTheSingletonAndDeletingItRestoresTheDefault() async throws {
      let database = try await settingsDatabase()

      @SingleRow(Settings.self, database: database) var settings
      try await $settings.save(Settings(id: 0, theme: "dark", launchCount: 4))
      try await waitUntil { settings.theme == "dark" && settings.launchCount == 4 }

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
      // The query helper refuses it the same way.
      await #expect(throws: OrbitRowIdentityMismatchError.self) {
        try await database.write { transaction in
          try Settings(id: 1, theme: "dark", launchCount: 0).save(in: transaction)
        }
      }
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
  ) async throws -> SQLiteQueue {
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
