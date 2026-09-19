import Foundation
import RemindersData
import SQLiteOrbit

public struct ReminderNotificationScheduler: Sendable {
  public static let categoryIdentifier = "REMINDER_DUE"
  public static let disabled = Self(center: DisabledReminderNotificationCenter())

  private static let requestIdentifierPrefix = "reminder."

  private let calendar: Calendar
  private let center: any ReminderNotificationCenter
  private let now: @Sendable () -> Date

  public init(
    center: any ReminderNotificationCenter = SystemReminderNotificationCenter(),
    calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = { .now }
  ) {
    self.calendar = calendar
    self.center = center
    self.now = now
  }

  public func reconcile(
    reminderID: Reminder.ID,
    in database: RemindersDatabase
  ) async throws {
    let reminder = try await database.read {
      try Reminder.find(reminderID).fetchOne($0)
    }
    let identifier = Self.requestIdentifier(for: reminderID)
    guard
      let reminder,
      let request = request(for: reminder)
    else {
      await center.removePendingNotificationRequests(withIdentifiers: [identifier])
      await center.removeDeliveredNotifications(withIdentifiers: [identifier])
      return
    }
    guard await center.authorizationStatus() == .authorized else { return }
    try await center.add(request)
  }

  public func reconcileAll(in database: RemindersDatabase) async throws {
    let reminders = try await database.read {
      try Self.scheduledReminders.fetchAll($0)
    }
    try await reconcile(reminders)
  }

  public func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization()
  }

  public func authorizationStatus() async -> ReminderNotificationAuthorizationStatus {
    await center.authorizationStatus()
  }

  func reconcile(_ reminders: [Reminder]) async throws {
    let requests = reminders.compactMap(request(for:))
    let desiredIdentifiers = Set(requests.map(\.identifier))
    let staleIdentifiers = await center.pendingNotificationRequestIdentifiers()
      .filter {
        $0.hasPrefix(Self.requestIdentifierPrefix)
          && !desiredIdentifiers.contains($0)
      }
    if !staleIdentifiers.isEmpty {
      await center.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
      await center.removeDeliveredNotifications(withIdentifiers: staleIdentifiers)
    }

    guard await center.authorizationStatus() == .authorized else { return }
    for request in requests {
      try await center.add(request)
    }
  }

  func request(for reminder: Reminder) -> ReminderNotificationRequest? {
    guard
      reminder.status == .incomplete,
      let dueDate = reminder.dueDate,
      let deliveryDate = deliveryDate(for: reminder, dueDate: dueDate),
      deliveryDate > now()
    else { return nil }

    let dateComponents = calendar.dateComponents(
      [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
      from: deliveryDate
    )
    return ReminderNotificationRequest(
      body: reminder.notes,
      categoryIdentifier: Self.categoryIdentifier,
      dateComponents: dateComponents,
      identifier: Self.requestIdentifier(for: reminder.id),
      reminderID: reminder.id,
      threadIdentifier: reminder.remindersListID.uuidString,
      title: reminder.title
    )
  }

  private func deliveryDate(for reminder: Reminder, dueDate: Date) -> Date? {
    guard !reminder.includesTime else { return dueDate }
    return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dueDate)
  }

  private static func requestIdentifier(for reminderID: Reminder.ID) -> String {
    requestIdentifierPrefix + reminderID.uuidString
  }

  static var scheduledReminders: some SelectStatement<(), Reminder, ()> {
    Reminder
      .where { !$0.isCompleted && $0.dueDate.isNot(nil) }
      .order { ($0.dueDate, $0.id) }
  }
}

private struct DisabledReminderNotificationCenter: ReminderNotificationCenter {
  func add(_ request: ReminderNotificationRequest) async throws {}

  func authorizationStatus() async -> ReminderNotificationAuthorizationStatus {
    .denied
  }

  func pendingNotificationRequestIdentifiers() async -> [String] {
    []
  }

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {}

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {}

  func requestAuthorization() async throws -> Bool {
    false
  }
}
