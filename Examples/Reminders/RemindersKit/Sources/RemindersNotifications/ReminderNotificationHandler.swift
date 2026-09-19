import Foundation
import RemindersData
import UserNotifications

public final class ReminderNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
  public static let completeActionIdentifier = "COMPLETE_REMINDER"

  private let database: RemindersDatabase
  private let scheduler: ReminderNotificationScheduler

  public init(
    database: RemindersDatabase,
    scheduler: ReminderNotificationScheduler = ReminderNotificationScheduler()
  ) {
    self.database = database
    self.scheduler = scheduler
  }

  public func register() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: ReminderNotificationScheduler.categoryIdentifier,
        actions: [
          UNNotificationAction(
            identifier: Self.completeActionIdentifier,
            title: "Complete"
          )
        ],
        intentIdentifiers: []
      )
    ])
  }

  public func complete(reminderID: Reminder.ID) async throws {
    try await Reminder.setStatus(.completed, id: reminderID, in: database)
    try await scheduler.reconcile(reminderID: reminderID, in: database)
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard
      response.actionIdentifier == Self.completeActionIdentifier,
      let reminderIDString = response.notification.request.content.userInfo["reminderID"]
        as? String,
      let reminderID = Reminder.ID(uuidString: reminderIDString)
    else { return }
    try? await complete(reminderID: reminderID)
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
