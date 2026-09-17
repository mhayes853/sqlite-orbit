import AppIntents
import RemindersData

struct CompleteReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Reminder"
  static let description = IntentDescription("Marks a reminder as completed.")
  static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  var reminderID: String

  init() {
    reminderID = ""
  }

  init(reminderID: Reminder.ID) {
    self.reminderID = reminderID.uuidString
  }

  func perform() async throws -> some IntentResult {
    guard let id = UUID(uuidString: reminderID) else { return .result() }
    try await RemindersWidgetStore.live().completeReminder(id: id)
    return .result()
  }
}
