import Foundation
import RemindersData
import UserNotifications

public enum ReminderNotificationIdentifiers {
  public static let category = "REMINDER_DUE"
  public static let completeAction = "COMPLETE_REMINDER"
  public static let reminderIDUserInfoKey = "reminderID"
  public static let requestPrefix = "reminder."

  public static func request(for reminderID: Reminder.ID) -> String {
    requestPrefix + reminderID.uuidString
  }
}

public struct ReminderNotificationRequest: Equatable, Sendable {
  public let body: String
  public let categoryIdentifier: String
  public let dateComponents: DateComponents
  public let identifier: String
  public let interruptionLevel: UNNotificationInterruptionLevel
  public let reminderID: Reminder.ID
  public let threadIdentifier: String
  public let title: String

  public init(
    body: String,
    categoryIdentifier: String,
    dateComponents: DateComponents,
    identifier: String,
    interruptionLevel: UNNotificationInterruptionLevel,
    reminderID: Reminder.ID,
    threadIdentifier: String,
    title: String
  ) {
    self.body = body
    self.categoryIdentifier = categoryIdentifier
    self.dateComponents = dateComponents
    self.identifier = identifier
    self.interruptionLevel = interruptionLevel
    self.reminderID = reminderID
    self.threadIdentifier = threadIdentifier
    self.title = title
  }
}

public protocol ReminderNotificationCenter: Sendable {
  func add(_ request: ReminderNotificationRequest) async throws
  func authorizationStatus() async -> UNAuthorizationStatus
  func deliveredNotificationRequestIdentifiers() async -> [String]
  func pendingNotificationRequestIdentifiers() async -> [String]
  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
  func requestAuthorization() async throws -> Bool
}

extension UNUserNotificationCenter: ReminderNotificationCenter {
  public func add(_ request: ReminderNotificationRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.categoryIdentifier = request.categoryIdentifier
    content.interruptionLevel = request.interruptionLevel
    content.sound = .default
    content.threadIdentifier = request.threadIdentifier
    content.userInfo = [
      ReminderNotificationIdentifiers.reminderIDUserInfoKey: request.reminderID.uuidString
    ]
    try await add(
      UNNotificationRequest(
        identifier: request.identifier,
        content: content,
        trigger: UNCalendarNotificationTrigger(
          dateMatching: request.dateComponents,
          repeats: false
        )
      )
    )
  }

  public func authorizationStatus() async -> UNAuthorizationStatus {
    await notificationSettings().authorizationStatus
  }

  public func pendingNotificationRequestIdentifiers() async -> [String] {
    await pendingNotificationRequests().map(\.identifier)
  }

  public func deliveredNotificationRequestIdentifiers() async -> [String] {
    await deliveredNotifications().map(\.request.identifier)
  }

  public func requestAuthorization() async throws -> Bool {
    try await requestAuthorization(options: [.alert, .sound])
  }
}

public struct DisabledReminderNotificationCenter: ReminderNotificationCenter {
  public init() {}

  public func add(_ request: ReminderNotificationRequest) async throws {}

  public func authorizationStatus() async -> UNAuthorizationStatus {
    .denied
  }

  public func deliveredNotificationRequestIdentifiers() async -> [String] {
    []
  }

  public func pendingNotificationRequestIdentifiers() async -> [String] {
    []
  }

  public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {}

  public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {}

  public func requestAuthorization() async throws -> Bool {
    false
  }
}
