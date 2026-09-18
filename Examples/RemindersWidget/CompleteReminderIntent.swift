import AppIntents
import RemindersData

enum RemindersWidgetEnvironment {
  static let database = try! makeAppDatabase()
}

struct CompleteReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Reminder"
  static let description = IntentDescription("Marks a reminder as completed.")
  static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  var reminderID: String

  private let database: RemindersDatabase

  init() {
    database = RemindersWidgetEnvironment.database
    reminderID = ""
  }

  init(reminderID: Reminder.ID) {
    self.init(reminderID: reminderID, database: RemindersWidgetEnvironment.database)
  }

  init(reminderID: Reminder.ID, database: RemindersDatabase) {
    self.database = database
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
