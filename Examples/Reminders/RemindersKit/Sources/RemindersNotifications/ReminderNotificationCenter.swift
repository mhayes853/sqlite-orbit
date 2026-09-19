import Foundation
import RemindersData
import UserNotifications

public struct ReminderNotificationRequest: Equatable, Sendable {
  public let body: String
  public let categoryIdentifier: String
  public let dateComponents: DateComponents
  public let identifier: String
  public let reminderID: Reminder.ID
  public let threadIdentifier: String
  public let title: String

  public init(
    body: String,
    categoryIdentifier: String,
    dateComponents: DateComponents,
    identifier: String,
    reminderID: Reminder.ID,
    threadIdentifier: String,
    title: String
  ) {
    self.body = body
    self.categoryIdentifier = categoryIdentifier
    self.dateComponents = dateComponents
    self.identifier = identifier
    self.reminderID = reminderID
    self.threadIdentifier = threadIdentifier
    self.title = title
  }
}

public enum ReminderNotificationAuthorizationStatus: Sendable {
  case authorized
  case denied
  case notDetermined
}

public protocol ReminderNotificationCenter: Sendable {
  func add(_ request: ReminderNotificationRequest) async throws
  func authorizationStatus() async -> ReminderNotificationAuthorizationStatus
  func pendingNotificationRequestIdentifiers() async -> [String]
  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
  func requestAuthorization() async throws -> Bool
}

public struct SystemReminderNotificationCenter: ReminderNotificationCenter {
  public init() {}

  public func add(_ request: ReminderNotificationRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.categoryIdentifier = request.categoryIdentifier
    content.sound = .default
    content.threadIdentifier = request.threadIdentifier
    content.userInfo = ["reminderID": request.reminderID.uuidString]
    try await UNUserNotificationCenter.current().add(
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

  public func authorizationStatus() async -> ReminderNotificationAuthorizationStatus {
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .authorized, .ephemeral, .provisional:
      .authorized
    case .denied:
      .denied
    case .notDetermined:
      .notDetermined
    @unknown default:
      .denied
    }
  }

  public func pendingNotificationRequestIdentifiers() async -> [String] {
    await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
  }

  public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: identifiers
    )
  }

  public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: identifiers
    )
  }

  public func requestAuthorization() async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
  }
}
