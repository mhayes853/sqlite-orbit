import Foundation
import RemindersData
import SQLiteOrbit

func makeTestDatabase() throws -> SQLiteQueue {
  try SQLiteQueue.reminders()
}

func insertFixture(
  lists: [RemindersList],
  reminders: [Reminder] = []
) async throws {
  try await OrbitDefaultDatabase.current.write { transaction in
    try RemindersList.insert { lists }.execute(transaction)
    if !reminders.isEmpty {
      try Reminder.insert { reminders }.execute(transaction)
    }
  }
}

func reminderFixture(
  title: String = "Call Blob"
) async throws -> (RemindersList, Reminder) {
  let list = RemindersList(id: UUID(), title: "Personal")
  let reminder = Reminder(id: UUID(), remindersListID: list.id, title: title)
  try await insertFixture(lists: [list], reminders: [reminder])
  return (list, reminder)
}
