import AppIntents
import Foundation
import RemindersData
import RemindersNotifications
import SQLiteOrbit

struct CompleteWidgetReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Reminder"
  static let description = IntentDescription("Marks a reminder as completed.")
  static let isDiscoverable = false
  static let supportedModes: IntentModes = [.background]

  @Parameter(title: "Reminder ID")
  var reminderID: String

  init() {
    reminderID = ""
  }

  init(reminderID: Reminder.ID) {
    self.reminderID = reminderID.uuidString
  }

  func perform() async throws -> some IntentResult {
    guard let reminderID = UUID(uuidString: reminderID) else {
      throw CompleteWidgetReminderError.invalidIdentifier
    }
    let database = try OrbitIPCDatabase.reminders()
    try await Reminder.setStatus(
      .completed,
      id: reminderID,
      in: database,
      scheduler: ReminderNotificationScheduler()
    )
    return .result()
  }
}

private enum CompleteWidgetReminderError: Error {
  case invalidIdentifier
}
