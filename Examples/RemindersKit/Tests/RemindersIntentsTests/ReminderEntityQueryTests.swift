import Foundation
import RemindersData
import SQLiteOrbit
import Testing

@testable import RemindersIntents

struct ReminderEntityQueryTests {
  @Test
  func reminderEntitiesIncludeTheirIntentProperties() async throws {
    let database = try SQLiteQueue.reminders()
    let personal = RemindersList(id: UUID(), title: "Personal")
    let work = RemindersList(id: UUID(), position: 1, title: "Work")
    let older = Reminder(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_000),
      remindersListID: personal.id,
      title: "Buy milk"
    )
    let newer = Reminder(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 2_000),
      dueDate: Date(timeIntervalSince1970: 3_000),
      isFlagged: true,
      notes: "Bring the launch numbers",
      priority: .high,
      remindersListID: work.id,
      title: "Finish presentation"
    )
    try await database.write { transaction in
      try RemindersList.insert {
        RemindersList.Draft(personal)
        RemindersList.Draft(work)
      }
      .execute(transaction)
      try Reminder.insert {
        Reminder.Draft(older)
        Reminder.Draft(newer)
      }
      .execute(transaction)
      try Tag.insert {
        Tag.Draft(Tag(title: "focus time"))
        Tag.Draft(Tag(title: "work"))
      }
      .execute(transaction)
      try ReminderTag.insert {
        ReminderTag.Draft(
          ReminderTag(id: UUID(), reminderID: newer.id, tagID: "focus time")
        )
        ReminderTag.Draft(
          ReminderTag(id: UUID(), reminderID: newer.id, tagID: "work")
        )
      }
      .execute(transaction)
    }

    let query = ReminderEntityQueries(database: database)
    let entities = try await query.entities(for: [newer.id, older.id])

    #expect(entities.map(\.id) == [newer.id, older.id])
    #expect(entities[0].title == "Finish presentation")
    #expect(entities[0].notes == "Bring the launch numbers")
    #expect(entities[0].list.title == "Work")
    #expect(entities[0].dueDate == Date(timeIntervalSince1970: 3_000))
    #expect(entities[0].isFlagged)
    #expect(entities[0].priority == .high)
    #expect(entities[0].tags == ["focus time", "work"])
    #expect(entities[0].createdAt == Date(timeIntervalSince1970: 2_000))
  }

  @Test
  func reminderEntitySearchUsesFTSAndSuggestionsExcludeCompleted() async throws {
    let database = try SQLiteQueue.reminders()
    let list = RemindersList(id: UUID(), title: "Personal")
    let completed = Reminder(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 3_000),
      remindersListID: list.id,
      status: .completed,
      title: "Completed launch notes"
    )
    let tagged = Reminder(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 2_000),
      remindersListID: list.id,
      title: "Book flights"
    )
    let newest = Reminder(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 4_000),
      remindersListID: list.id,
      title: "Call the venue"
    )
    try await database.write { transaction in
      try RemindersList.insert { RemindersList.Draft(list) }.execute(transaction)
      try Reminder.insert {
        Reminder.Draft(completed)
        Reminder.Draft(tagged)
        Reminder.Draft(newest)
      }
      .execute(transaction)
      try Tag.insert { Tag.Draft(Tag(title: "travel plans")) }.execute(transaction)
      try ReminderTag.insert {
        ReminderTag.Draft(
          ReminderTag(id: UUID(), reminderID: tagged.id, tagID: "travel plans")
        )
      }
      .execute(transaction)
    }

    let query = ReminderEntityQueries(database: database)

    let suggestions = try await query.suggestedEntities()
    let matches = try await query.entities(matching: "travel plans")
    #expect(suggestions.map(\.id) == [newest.id, tagged.id])
    #expect(matches.map(\.id) == [tagged.id])
  }

  @Test
  func remindersListQueryResolvesAndSearchesLists() async throws {
    let database = try SQLiteQueue.reminders()
    let personal = RemindersList(id: UUID(), title: "Personal")
    let work = RemindersList(id: UUID(), position: 1, title: "Work Projects")
    try await database.write { transaction in
      try RemindersList.insert {
        RemindersList.Draft(personal)
        RemindersList.Draft(work)
      }
      .execute(transaction)
    }
    let query = RemindersListEntityQueries(database: database)

    let resolved = try await query.entities(for: [work.id, personal.id])
    let matches = try await query.entities(matching: "project")
    #expect(resolved.map(\.id) == [work.id, personal.id])
    #expect(matches.map(\.id) == [work.id])
  }
}
