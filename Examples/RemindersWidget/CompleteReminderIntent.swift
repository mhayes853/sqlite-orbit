import AppIntents
import RemindersData

enum RemindersWidgetDependencyKey {
  static let database = "RemindersWidgetDatabase"
}

struct CompleteReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Reminder"
  static let description = IntentDescription("Marks a reminder as completed.")
  static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  var reminderID: String

  @Dependency(key: RemindersWidgetDependencyKey.database)
  private var database: RemindersDatabase

  init() {
    reminderID = ""
  }

  init(reminderID: Reminder.ID) {
    self.reminderID = reminderID.uuidString
  }

  init(reminderID: Reminder.ID, dependencyManager: AppDependencyManager) {
    _database = AppDependency(manager: dependencyManager)
    self.reminderID = reminderID.uuidString
  }

  func perform() async throws -> some IntentResult {
    guard let id = UUID(uuidString: reminderID) else { return .result() }
    try await database.write { transaction in
      try Reminder.complete(id: id).execute(transaction)
    }
    return .result()
  }
}
