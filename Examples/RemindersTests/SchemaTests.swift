import Foundation
import RemindersData
import SQLiteOrbit
import SQLiteOrbitTestSupport
import Testing

@testable import RemindersFeature

@Suite(.orbitDatabase(try makeTestDatabase()))
struct SchemaTests {
  @Test
  func migratedDatabaseStartsEmpty() async throws {
    let database = OrbitDefaultDatabase.current

    let counts = try await database.read { transaction in
      try (
        RemindersList.count().fetchOne(transaction) ?? -1,
        Reminder.count().fetchOne(transaction) ?? -1,
        Tag.count().fetchOne(transaction) ?? -1,
        RemindersDetailSettings.count().fetchOne(transaction) ?? -1,
        SearchSettings.count().fetchOne(transaction) ?? -1
      )
    }

    #expect(counts.0 == 0)
    #expect(counts.1 == 0)
    #expect(counts.2 == 0)
    #expect(counts.3 == 0)
    #expect(counts.4 == 0)
  }

  @Test
  func searchSettingsReadTheirDefaultWithoutInsertingAndPersistOneRow() async throws {
    let database = OrbitDefaultDatabase.current

    let initial = try await database.read { try SearchSettings.find(in: $0) }
    #expect(initial == .defaultValue)
    #expect(try await database.read { try SearchSettings.count().fetchOne($0) } == 0)

    try await database.write { transaction in
      try SearchSettings.update(in: transaction) { $0.showCompleted = true }
    }

    let persisted = try await database.read { try SearchSettings.find(in: $0) }
    #expect(persisted.showCompleted)
    #expect(try await database.read { try SearchSettings.count().fetchOne($0) } == 1)
  }

  @Test
  func deletingListCascadesRelatedRows() async throws {
    let database = OrbitDefaultDatabase.current
    let listID = UUID()
    let reminderID = UUID()

    try await database.write { transaction in
      try RemindersList.insert {
        RemindersList(id: listID, title: "Personal")
      }
      .execute(transaction)
      try RemindersListAsset.insert {
        RemindersListAsset(remindersListID: listID, coverImage: Data([0, 1, 2]))
      }
      .execute(transaction)
      try Reminder.insert {
        Reminder(id: reminderID, remindersListID: listID, title: "Buy milk")
      }
      .execute(transaction)
      try Tag.insert { Tag(title: "errands") }.execute(transaction)
      try ReminderTag.insert {
        ReminderTag(id: UUID(), reminderID: reminderID, tagID: "errands")
      }
      .execute(transaction)
      try RemindersList.find(listID).delete().execute(transaction)
    }

    let counts = try await database.read { transaction in
      try (
        Reminder.count().fetchOne(transaction) ?? -1,
        RemindersListAsset.count().fetchOne(transaction) ?? -1,
        ReminderTag.count().fetchOne(transaction) ?? -1,
        Tag.count().fetchOne(transaction) ?? -1
      )
    }

    #expect(counts.0 == 0)
    #expect(counts.1 == 0)
    #expect(counts.2 == 0)
    #expect(counts.3 == 1)
  }

  @Test
  func detailSettingsArePersistedInDatabase() async throws {
    let database = OrbitDefaultDatabase.current
    let settings = RemindersDetailSettings(
      id: "today",
      ordering: .priority,
      showCompleted: true
    )

    try await database.write { transaction in
      try RemindersDetailSettings.insert { settings }.execute(transaction)
    }

    let persisted = try await database.read { transaction in
      try RemindersDetailSettings.find("today").fetchOne(transaction)
    }

    #expect(persisted == settings)
  }
}
