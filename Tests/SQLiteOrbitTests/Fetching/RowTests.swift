#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct RowTests {
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
  ) async throws -> OrbitDatabase<SQLiteQueue> {
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
