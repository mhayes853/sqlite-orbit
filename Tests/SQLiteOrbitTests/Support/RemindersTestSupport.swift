#if BuiltInSQLite
  import SQLiteOrbit

  let remindersSchema = """
    CREATE TABLE IF NOT EXISTS reminders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      isCompleted INTEGER NOT NULL DEFAULT 0,
      priority TEXT
    )
    """

  func remindersDatabase(titles: String...) async throws -> SQLiteQueue {
    let database = try inMemoryDatabase()
    try await database.write { transaction in
      try transaction.execute(remindersSchema)
      try transaction.execute(
        "CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)"
      )
      for title in titles {
        try transaction.execute(
          RemindersTestFixture.Reminder.insert {
            RemindersTestFixture.Reminder.Draft(title: title)
          }
        )
      }
    }
    return database
  }

  func insertReminders(
    _ titles: String...,
    into database: some OrbitDatabaseWriter
  ) async throws {
    try await database.write { transaction in
      for title in titles {
        try transaction.execute(
          RemindersTestFixture.Reminder.insert {
            RemindersTestFixture.Reminder.Draft(title: title)
          }
        )
      }
    }
  }

  enum RemindersTestFixture {
    @Table("reminders")
    struct Reminder: Equatable, Sendable {
      let id: Int
      var title: String
      var isCompleted = false
      var priority: String?
    }
  }
#endif
