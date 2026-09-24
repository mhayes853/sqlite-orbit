import Foundation
import RemindersData
import SQLiteOrbit
import Testing
import UserNotifications

@testable import RemindersNotifications

struct ReminderNotificationSchedulerTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  @Test(arguments: [false, true])
  func reminderBuildsARequest(allDay: Bool) throws {
    let dueDate = try #require(
      calendar.date(from: DateComponents(year: 2030, month: 2, day: 3, hour: 14, minute: 30))
    )
    let reminder = Reminder(
      id: UUID(),
      dueDate: allDay
        ? ReminderDate(date: dueDate, calendar: calendar)
        : ReminderDate(dateAndTime: dueDate, calendar: calendar),
      notes: allDay ? "" : "Remember the slides",
      remindersListID: UUID(),
      title: allDay ? "All day" : "Present"
    )
    let scheduler = ReminderNotificationScheduler(
      center: TestReminderNotificationCenter(),
      calendar: calendar,
      now: { .distantPast }
    )

    let request = try #require(scheduler.request(for: reminder))
    #expect(
      request.identifier == ReminderNotificationIdentifiers.request(for: reminder.id)
    )
    #expect(request.title == reminder.title)
    #expect(request.body == reminder.notes)
    #expect(request.interruptionLevel == (allDay ? .active : .timeSensitive))
    #expect(request.threadIdentifier == reminder.remindersListID.uuidString)
    #expect(request.dateComponents.year == 2030)
    #expect(request.dateComponents.month == 2)
    #expect(request.dateComponents.day == 3)
    #expect(request.dateComponents.hour == (allDay ? 9 : 14))
    #expect(request.dateComponents.minute == (allDay ? 0 : 30))
  }

  @Test(.timeLimit(.minutes(1)))
  func observationReplacesTheReminderNotificationSet() async throws {
    let (database, reminder) = try await reminderFixture(
      dueDate: ReminderDate(dateAndTime: .distantFuture, calendar: calendar),
      title: "Future"
    )
    let staleIdentifier = ReminderNotificationIdentifiers.request(for: UUID())
    let stale = notificationRequest(identifier: staleIdentifier)
    let unrelated = notificationRequest(identifier: "another-feature")
    let (identifiers, continuation) = AsyncStream.makeStream(of: String.self)
    let center = TestReminderNotificationCenter(
      requests: [stale, unrelated],
      onAdd: { continuation.yield($0.identifier) }
    )
    let scheduler = ReminderNotificationScheduler(
      center: center,
      calendar: calendar,
      now: { .distantPast }
    )
    let observation = Task { await scheduler.observe(in: database) }
    defer { observation.cancel() }

    let reminderIdentifier = ReminderNotificationIdentifiers.request(for: reminder.id)
    #expect(await identifiers.first { $0 == reminderIdentifier } != nil)

    #expect(
      await center.requestIdentifiers()
        == ["another-feature", reminderIdentifier]
    )
    #expect(await center.removedDeliveredIdentifiers() == [staleIdentifier])
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
    let observation = Task { await scheduler.observe(in: database) }
    defer { observation.cancel() }

    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }

    let identifier = await identifiers.first { identifier in
      identifier == ReminderNotificationIdentifiers.request(for: reminder.id)
    }
    #expect(identifier != nil)
  }

  @Test
  func notificationHandlerCompletesTheReminder() async throws {
    let (database, reminder) = try await reminderFixture(
      dueDate: ReminderDate(date: .distantFuture, calendar: calendar),
      title: "Complete me"
    )
    let center = TestReminderNotificationCenter(
      requests: [
        notificationRequest(
          identifier: ReminderNotificationIdentifiers.request(for: reminder.id)
        )
      ]
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

  @Test @MainActor
  func notificationHandlerOpensTheReminderForTheDefaultAction() async throws {
    let reminderID = UUID()
    let openedReminderIDs = OpenedReminderIDs()
    let handler = ReminderNotificationHandler(
      database: try SQLiteQueue.reminders(),
      scheduler: .disabled,
      openReminder: { reminderID in
        openedReminderIDs.append(reminderID)
      }
    )

    await handler.handle(
      actionIdentifier: UNNotificationDefaultActionIdentifier,
      reminderID: reminderID
    )

    #expect(openedReminderIDs.values == [reminderID])
  }

  private func notificationRequest(identifier: String) -> ReminderNotificationRequest {
    ReminderNotificationRequest(
      body: "",
      categoryIdentifier: "",
      dateComponents: DateComponents(),
      identifier: identifier,
      interruptionLevel: .active,
      reminderID: UUID(),
      threadIdentifier: "",
      title: ""
    )
  }

  private func reminderFixture(
    dueDate: ReminderDate,
    title: String
  ) async throws -> (SQLiteQueue, Reminder) {
    let database = try SQLiteQueue.reminders()
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      dueDate: dueDate,
      remindersListID: list.id,
      title: title
    )
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }
    return (database, reminder)
  }
}

@MainActor
private final class OpenedReminderIDs {
  var values: [Reminder.ID] = []

  func append(_ reminderID: Reminder.ID) {
    values.append(reminderID)
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

  func authorizationStatus() async -> UNAuthorizationStatus {
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
