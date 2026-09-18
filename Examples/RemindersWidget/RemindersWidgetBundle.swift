import AppIntents
import RemindersData
import SQLiteOrbit
import SwiftUI
import WidgetKit

@main
struct RemindersWidgetBundle: WidgetBundle {
  private let database: RemindersDatabase

  init() {
    let database = try! OrbitIPCDatabase.reminders()
    self.database = database
    AppDependencyManager.shared.add(
      dependency: RemindersWidgetDatabase(database: database)
    )
  }

  var body: some Widget {
    RecentRemindersWidget(database: database)
  }
}

private struct RemindersWidgetDatabase: Sendable {
  let database: RemindersDatabase
}

struct CompleteWidgetReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Reminder"
  static let description = IntentDescription("Marks a widget reminder as completed.")
  static let isDiscoverable = false
  static let openAppWhenRun = false

  @Parameter(title: "Reminder ID")
  var reminderID: String

  @Dependency
  private var databaseDependency: RemindersWidgetDatabase

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
    try await databaseDependency.database.write {
      try Reminder.setStatus(.completed, id: reminderID).execute($0)
    }
    WidgetCenter.shared.reloadTimelines(ofKind: RemindersWidgetConfiguration.kind)
    return .result()
  }
}

private enum CompleteWidgetReminderError: LocalizedError {
  case invalidIdentifier

  var errorDescription: String? {
    "The reminder could not be found."
  }
}
