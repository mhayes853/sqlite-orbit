import Foundation
import RemindersData
import UserNotifications

public final class ReminderNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
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
        identifier: ReminderNotificationIdentifiers.category,
        actions: [
          UNNotificationAction(
            identifier: ReminderNotificationIdentifiers.completeAction,
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
      response.actionIdentifier == ReminderNotificationIdentifiers.completeAction,
      let reminderIDString = response.notification.request.content.userInfo[
        ReminderNotificationIdentifiers.reminderIDUserInfoKey
      ] as? String,
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
