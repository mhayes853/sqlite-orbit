#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Testing

    @testable import SQLiteOrbit

    @Suite
    struct RowTests {
      @Test
      func anObservableReaderDefaultRejectsSavingAndRecordsTheError() async throws {
        let database = try await rowsDatabase(EditableReminder(id: 1, title: "Milk", notes: ""))
        try await OrbitDefaultDatabase.withValue(ReaderOnlyObservationDatabase(database)) {
          @Row(EditableReminder.self, id: 1) var reminder
          #expect(reminder?.title == "Milk")
          do {
            try await $reminder.update { $0.title = "Eggs" }
            Issue.record("The reader-only default accepted a save")
          } catch {
            #expect((error as? SQLiteError)?.primaryCode == .readOnly)
          }
          #expect(($reminder.saveError as? SQLiteError)?.primaryCode == .readOnly)
          #expect(!$reminder.isSaving)
          #expect(reminder?.title == "Milk")
        }
      }

      @Test(arguments: [false, true])
      func savingRemainsTrueUntilAHeldUpdateCompletes(overlappingFailure: Bool) async throws {
        let database = try await rowsDatabase(EditableReminder(id: 1, title: "Milk", notes: ""))
        @Row(EditableReminder.self, id: 1, database: database) var reminder
        let property = $reminder
        let gate = TestGate()
        defer { gate.open() }
        let update = Task {
          try await property.update { value in
            value.title = "Eggs"
            try gate.enter()
          }
        }
        defer { update.cancel() }
        try await gate.waitUntilEntered()
        #expect(property.isSaving)
        if overlappingFailure {
          // This save fails before reaching the database, while the first update is still held.
          await #expect(throws: OrbitRowIdentityMismatchError.self) {
            try await property.save(EditableReminder(id: 2, title: "wrong", notes: ""))
          }
          #expect(property.saveError is OrbitRowIdentityMismatchError)
          #expect(property.isSaving)
        }
        gate.open()
        try await update.value
        #expect(!property.isSaving)
        if !overlappingFailure { #expect(property.saveError == nil) }
        let persisted = try await database.read { try $0.find(EditableReminder.all, key: 1) }
        var expected = EditableReminder(id: 1, title: "Milk", notes: "")
        expected.title = "Eggs"
        #expect(persisted == expected)
        try await property.save(expected)
        #expect(property.saveError == nil)
        #expect(!property.isSaving)
      }

      @Test(arguments: ["mutation", "identity", "constraint"])
      func failedUpdatePreservesDataAndASuccessfulSaveClearsTheError(failure: String) async throws {
        let database = try await rowsDatabase(EditableReminder(id: 1, title: "Milk", notes: ""))
        @Row(EditableReminder.self, id: 1, database: database) var reminder
        if failure == "constraint" {
          try await database.write {
            try $0.executeScript(
              "CREATE TRIGGER reject_update BEFORE UPDATE ON editableReminders BEGIN SELECT RAISE(ABORT, 'refused'); END"
            )
          }
        }
        do {
          try await $reminder.update { value in
            value.title = "Eggs"
            if failure == "mutation" { throw TestError() }
            if failure == "identity" {
              value = EditableReminder(id: 2, title: "changed", notes: "")
            }
          }
          Issue.record("The update should fail for \(failure)")
        } catch {
          switch failure {
          case "mutation": #expect(error is TestError)
          case "identity": #expect(error is OrbitRowIdentityMismatchError)
          default: #expect((error as? SQLiteError)?.primaryCode == .constraint)
          }
        }
        #expect(!$reminder.isSaving)
        #expect($reminder.saveError != nil)
        let unchanged = try await database.read { try $0.find(EditableReminder.all, key: 1) }
        #expect(unchanged == EditableReminder(id: 1, title: "Milk", notes: ""))
        if failure == "constraint" {
          try await database.write { try $0.execute("DROP TRIGGER reject_update") }
        }
        var replacement = EditableReminder(id: 1, title: "Milk", notes: "")
        replacement.title = "Eggs"
        try await $reminder.save(replacement)
        #expect(!$reminder.isSaving)
        #expect($reminder.saveError == nil)
        let persisted = try await database.read { try $0.find(EditableReminder.all, key: 1) }
        #expect(persisted == replacement)
      }

      @Test
      func aMissingRowIsNilAndLaterInsertionIsObserved() async throws {
        let database = try await rowsDatabase()

        @Row(EditableReminder.self, id: 1, database: database) var reminder

        #expect(reminder == nil)
        try await database.write { transaction in
          try transaction.execute(
            EditableReminder.insert {
              EditableReminder(id: 1, title: "Milk", notes: "")
            }
          )
        }
        try await waitUntil { reminder?.title == "Milk" }
      }

      @Test
      func saveReplacesAnExistingRow() async throws {
        let database = try await rowsDatabase(
          EditableReminder(id: 1, title: "Milk", notes: "cold")
        )

        @Row(EditableReminder.self, id: 1, database: database) var reminder
        #expect(reminder?.title == "Milk")

        try await $reminder.save(
          EditableReminder(id: 1, title: "Oat milk", notes: "shelf stable")
        )

        try await waitUntil {
          reminder == EditableReminder(id: 1, title: "Oat milk", notes: "shelf stable")
        }
      }

      @Test
      func saveDoesNotRecreateAMissingRow() async throws {
        let database = try await rowsDatabase()

        @Row(EditableReminder.self, id: 1, database: database) var reminder

        await #expect(throws: OrbitDatabaseRecordNotFoundError.self) {
          try await $reminder.save(EditableReminder(id: 1, title: "Milk", notes: ""))
        }
        #expect($reminder.saveError is OrbitDatabaseRecordNotFoundError)
        #expect(reminder == nil)
      }

      @Test
      func updateReadsTheLatestRowInsideItsWriteTransaction() async throws {
        let database = try await rowsDatabase(
          EditableReminder(id: 1, title: "Milk", notes: "")
        )

        @Row(EditableReminder.self, id: 1, database: database) var reminder
        _ = reminder
        try await database.write { transaction in
          try transaction.execute(
            EditableReminder.update(
              EditableReminder(id: 1, title: "Milk", notes: "from another writer")
            )
          )
        }

        let oldTitle = try await $reminder.update { reminder in
          let oldTitle = reminder.title
          reminder.title = "Eggs"
          return oldTitle
        }

        #expect(oldTitle == "Milk")
        let persisted = try await database.read { transaction in
          try transaction.find(EditableReminder.all, key: 1)
        }
        #expect(
          persisted == EditableReminder(id: 1, title: "Eggs", notes: "from another writer")
        )
      }

      @Test
      func changingThePrimaryKeyIsRejected() async throws {
        let database = try await rowsDatabase(
          EditableReminder(id: 1, title: "Milk", notes: "")
        )

        @Row(EditableReminder.self, id: 1, database: database) var reminder

        await #expect(throws: OrbitRowIdentityMismatchError.self) {
          try await $reminder.save(EditableReminder(id: 2, title: "Milk", notes: ""))
        }
        #expect($reminder.saveError is OrbitRowIdentityMismatchError)
      }

      @Test
      func deleteRemovesTheObservedRowAndReportsASecondDeletion() async throws {
        let database = try await rowsDatabase(
          EditableReminder(id: 1, title: "Milk", notes: "")
        )

        @Row(EditableReminder.self, id: 1, database: database) var reminder
        #expect(reminder != nil)

        try await $reminder.delete()
        try await waitUntil { reminder == nil }

        await #expect(throws: OrbitDatabaseRecordNotFoundError.self) {
          try await $reminder.delete()
        }
      }
    }

    private func rowsDatabase(
      _ rows: EditableReminder...
    ) async throws -> SQLiteQueue {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE editableReminders (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            notes TEXT NOT NULL
          )
          """
        )
        for row in rows {
          try transaction.execute(EditableReminder.insert { row })
        }
      }
      return database
    }

    @Table("editableReminders")
    private struct EditableReminder: Equatable, Sendable {
      let id: Int
      var title: String
      var notes: String
    }
  #endif
#endif
