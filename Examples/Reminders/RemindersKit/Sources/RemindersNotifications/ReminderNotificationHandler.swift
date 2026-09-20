import Foundation
import RemindersData
import UserNotifications

public final class ReminderNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
  private let database: RemindersDatabase
  private let openReminder: @MainActor @Sendable (Reminder.ID) async -> Void
  private let scheduler: ReminderNotificationScheduler

  public init(
    database: RemindersDatabase,
    scheduler: ReminderNotificationScheduler = ReminderNotificationScheduler(),
    openReminder: @escaping @MainActor @Sendable (Reminder.ID) async -> Void = { _ in }
  ) {
    self.database = database
    self.openReminder = openReminder
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
    try await Self.complete(
      reminderID: reminderID,
      database: database,
      scheduler: scheduler
    )
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    guard
      let reminderIDString = response.notification.request.content.userInfo[
        ReminderNotificationIdentifiers.reminderIDUserInfoKey
      ] as? String,
      let reminderID = Reminder.ID(uuidString: reminderIDString)
    else {
      completionHandler()
      return
    }
    let actionIdentifier = response.actionIdentifier
    let database = database
    let openReminder = openReminder
    let scheduler = scheduler
    Task { @MainActor in
      await Self.handle(
        actionIdentifier: actionIdentifier,
        reminderID: reminderID,
        database: database,
        scheduler: scheduler,
        openReminder: openReminder
      )
      completionHandler()
    }
  }

  func handle(actionIdentifier: String, reminderID: Reminder.ID) async {
    await Self.handle(
      actionIdentifier: actionIdentifier,
      reminderID: reminderID,
      database: database,
      scheduler: scheduler,
      openReminder: openReminder
    )
  }

  private static func handle(
    actionIdentifier: String,
    reminderID: Reminder.ID,
    database: RemindersDatabase,
    scheduler: ReminderNotificationScheduler,
    openReminder: @MainActor @Sendable (Reminder.ID) async -> Void
  ) async {
    switch actionIdentifier {
    case UNNotificationDefaultActionIdentifier:
      await openReminder(reminderID)
    case ReminderNotificationIdentifiers.completeAction:
      try? await complete(
        reminderID: reminderID,
        database: database,
        scheduler: scheduler
      )
    default:
      break
    }
  }

  private static func complete(
    reminderID: Reminder.ID,
    database: RemindersDatabase,
    scheduler: ReminderNotificationScheduler
  ) async throws {
    try await Reminder.setStatus(.completed, id: reminderID, in: database)
    try await scheduler.reconcile(reminderID: reminderID, in: database)
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
