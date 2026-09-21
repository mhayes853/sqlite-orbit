import AppIntents
import Foundation
import RemindersData
import RemindersNotifications
import SQLiteOrbit
import WidgetKit

struct CompleteWidgetReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Reminder"
  static let description = IntentDescription("Marks a reminder as completed.")
  static let isDiscoverable = false
  static let supportedModes: IntentModes = [.background]

  @available(iOS 27, macOS 27, tvOS 27, watchOS 27, visionOS 27, *)
  static let allowedExecutionTargets: IntentExecutionTargets = [.widgetKitExtension]

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
    try await Reminder.setStatus(
      .completed,
      id: reminderID,
      in: OrbitDefaultDatabase.current,
      scheduler: ReminderNotificationScheduler()
    )
    WidgetCenter.shared.reloadTimelines(ofKind: RemindersWidgetConfiguration.kind)
    return .result()
  }
}

private enum CompleteWidgetReminderError: Error {
  case invalidIdentifier
}
