import Foundation
import OSLog
import RemindersData
import SQLiteOrbit
import UserNotifications

public final class ReminderNotificationScheduler: Sendable {
  public static let disabled = ReminderNotificationScheduler(
    center: DisabledReminderNotificationCenter()
  )

  private let calendar: Calendar
  private let center: any ReminderNotificationCenter
  private let now: @Sendable () -> Date

  public init(
    center: any ReminderNotificationCenter = UNUserNotificationCenter.current(),
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
    let identifier = ReminderNotificationIdentifiers.request(for: reminderID)
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

  public func observe(in database: RemindersDatabase) async {
    let observation = OrbitValueObservation
      .trackingAll(Self.scheduledReminders)
      .removeDuplicates()
    do {
      for try await reminders in observation.values(in: database) {
        if
          !reminders.isEmpty,
          await center.authorizationStatus() == .notDetermined
        {
          _ = try await center.requestAuthorization()
        }
        try await reconcile(reminders)
      }
    } catch is CancellationError {
    } catch {
      Logger.remindersNotifications.error(
        "Reminder notification observation failed: \(error.localizedDescription)"
      )
    }
  }

  private func reconcile(_ reminders: [Reminder]) async throws {
    let requests = reminders.compactMap(request(for:))
    let desiredIdentifiers = Set(requests.map(\.identifier))
    async let pendingIdentifiers = center.pendingNotificationRequestIdentifiers()
    async let deliveredIdentifiers = center.deliveredNotificationRequestIdentifiers()
    let staleIdentifiers = Array(
      Set(await pendingIdentifiers + deliveredIdentifiers)
        .filter {
          $0.hasPrefix(ReminderNotificationIdentifiers.requestPrefix)
            && !desiredIdentifiers.contains($0)
        }
    )
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
      let deliveryDate = deliveryDate(for: dueDate),
      deliveryDate > now()
    else { return nil }

    let dateComponents = calendar.dateComponents(
      [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
      from: deliveryDate
    )
    return ReminderNotificationRequest(
      body: reminder.notes,
      categoryIdentifier: ReminderNotificationIdentifiers.category,
      dateComponents: dateComponents,
      identifier: ReminderNotificationIdentifiers.request(for: reminder.id),
      reminderID: reminder.id,
      threadIdentifier: reminder.remindersListID.uuidString,
      title: reminder.title
    )
  }

  private func deliveryDate(for dueDate: ReminderDate) -> Date? {
    var components = dueDate.components
    if dueDate.isAllDay {
      components.hour = 9
      components.minute = 0
    }
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    return components.date
  }

  private static var scheduledReminders: some SelectStatement<(), Reminder, ()> {
    Reminder
      .where { !$0.isCompleted && $0.dueDate.isNot(nil) }
      .order { ($0.dueDate, $0.id) }
  }
}

private extension Logger {
  static let remindersNotifications = Logger(
    subsystem: "co.sqlite-orbit.Reminders",
    category: "Notifications"
  )
}
