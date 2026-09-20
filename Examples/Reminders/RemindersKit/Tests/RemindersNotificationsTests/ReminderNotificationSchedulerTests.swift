import Foundation
import RemindersData
import SQLiteOrbit
import Testing

@testable import RemindersNotifications

struct ReminderNotificationSchedulerTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  @Test
  func timedReminderBuildsARequestAtItsDueDate() throws {
    let dueDate = try #require(
      calendar.date(from: DateComponents(year: 2030, month: 2, day: 3, hour: 14, minute: 30))
    )
    let reminder = Reminder(
      id: UUID(),
      dueDate: ReminderDate(dateAndTime: dueDate, calendar: calendar),
      notes: "Remember the slides",
      remindersListID: UUID(),
      title: "Present"
    )
    let scheduler = ReminderNotificationScheduler(
      center: TestReminderNotificationCenter(),
      calendar: calendar,
      now: { .distantPast }
    )

    let request = try #require(scheduler.request(for: reminder))
    #expect(request.identifier == "reminder.\(reminder.id.uuidString)")
    #expect(request.title == "Present")
    #expect(request.body == "Remember the slides")
    #expect(request.threadIdentifier == reminder.remindersListID.uuidString)
    #expect(request.dateComponents.year == 2030)
    #expect(request.dateComponents.month == 2)
    #expect(request.dateComponents.day == 3)
    #expect(request.dateComponents.hour == 14)
    #expect(request.dateComponents.minute == 30)
  }

  @Test
  func dateOnlyReminderBuildsARequestForNineAM() throws {
    let dueDate = try #require(
      calendar.date(from: DateComponents(year: 2030, month: 2, day: 3))
    )
    let reminder = Reminder(
      id: UUID(),
      dueDate: ReminderDate(date: dueDate, calendar: calendar),
      remindersListID: UUID(),
      title: "All day"
    )
    let scheduler = ReminderNotificationScheduler(
      center: TestReminderNotificationCenter(),
      calendar: calendar,
      now: { .distantPast }
    )

    let request = try #require(scheduler.request(for: reminder))
    #expect(request.dateComponents.hour == 9)
    #expect(request.dateComponents.minute == 0)
  }

  @Test
  func reconcileAllReplacesTheReminderNotificationSet() async throws {
    let database = try SQLiteQueue.reminders()
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      dueDate: ReminderDate(dateAndTime: .distantFuture, calendar: calendar),
      remindersListID: list.id,
      title: "Future"
    )
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }
    let stale = notificationRequest(identifier: "reminder.stale")
    let unrelated = notificationRequest(identifier: "another-feature")
    let center = TestReminderNotificationCenter(requests: [stale, unrelated])
    let scheduler = ReminderNotificationScheduler(
      center: center,
      calendar: calendar,
      now: { .distantPast }
    )

    try await scheduler.reconcileAll(in: database)

    #expect(
      await center.requestIdentifiers()
        == ["another-feature", "reminder.\(reminder.id.uuidString)"]
    )
    #expect(await center.removedDeliveredIdentifiers() == ["reminder.stale"])
  }

  @Test(.timeLimit(.minutes(1)))
  func observationSchedulesAfterADatabaseWrite() async throws {
    let database = try SQLiteQueue.reminders()
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      dueDate: ReminderDate(dateAndTime: .distantFuture, calendar: calendar),
      remindersListID: list.id,
      title: "Observed"
    )
    let (identifiers, continuation) = AsyncStream.makeStream(of: String.self)
    let center = TestReminderNotificationCenter { continuation.yield($0.identifier) }
    let scheduler = ReminderNotificationScheduler(
      center: center,
      calendar: calendar,
      now: { .distantPast }
    )
    let observation = ReminderNotificationObservation(
      database: database,
      scheduler: scheduler
    )

    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }

    let identifier = await identifiers.first { identifier in
      identifier == "reminder.\(reminder.id.uuidString)"
    }
    #expect(identifier != nil)
    _ = observation
  }

  @Test
  func notificationHandlerCompletesTheReminder() async throws {
    let database = try SQLiteQueue.reminders()
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      dueDate: ReminderDate(date: .distantFuture, calendar: calendar),
      remindersListID: list.id,
      title: "Complete me"
    )
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }
    let center = TestReminderNotificationCenter(
      requests: [notificationRequest(identifier: "reminder.\(reminder.id.uuidString)")]
    )
    let handler = ReminderNotificationHandler(
      database: database,
      scheduler: ReminderNotificationScheduler(center: center)
    )

    try await handler.complete(reminderID: reminder.id)

    let status = try await database.read {
      try Reminder.find(reminder.id).select(\.status).fetchOne($0)
    }
    #expect(status == .completed)
    #expect(await center.requestIdentifiers().isEmpty)
  }

  private func notificationRequest(identifier: String) -> ReminderNotificationRequest {
    ReminderNotificationRequest(
      body: "",
      categoryIdentifier: "",
      dateComponents: DateComponents(),
      identifier: identifier,
      reminderID: UUID(),
      threadIdentifier: "",
      title: ""
    )
  }
}

private actor TestReminderNotificationCenter: ReminderNotificationCenter {
  private var requests: [String: ReminderNotificationRequest]
  private var removedDelivered: [String] = []
  private let onAdd: @Sendable (ReminderNotificationRequest) -> Void

  init(
    requests: [ReminderNotificationRequest] = [],
    onAdd: @escaping @Sendable (ReminderNotificationRequest) -> Void = { _ in }
  ) {
    self.requests = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
    self.onAdd = onAdd
  }

  func add(_ request: ReminderNotificationRequest) async throws {
    requests[request.identifier] = request
    onAdd(request)
  }

  func authorizationStatus() async -> ReminderNotificationAuthorizationStatus {
    .authorized
  }

  func deliveredNotificationRequestIdentifiers() async -> [String] {
    []
  }

  func pendingNotificationRequestIdentifiers() async -> [String] {
    Array(requests.keys)
  }

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
    removedDelivered.append(contentsOf: identifiers)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
    for identifier in identifiers {
      requests[identifier] = nil
    }
  }

  func requestAuthorization() async throws -> Bool {
    true
  }

  func removedDeliveredIdentifiers() -> [String] {
    removedDelivered.sorted()
  }

  func requestIdentifiers() -> [String] {
    requests.keys.sorted()
  }
}
