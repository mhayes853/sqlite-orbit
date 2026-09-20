import AppIntents
import Foundation
import RemindersData
import RemindersNotifications
import SQLiteOrbit
import Testing
import UserNotifications

@testable import RemindersIntents

struct ReminderIntentTests {
  @Test
  func createReminderPersistsAllDetailsAndExplicitTags() async throws {
    let database = try SQLiteQueue.reminders()
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write {
      try RemindersList.insert { RemindersList.Draft(list) }.execute($0)
    }
    let dueDate = Date(timeIntervalSince1970: 12_360)
    let intent = CreateReminderIntent(
      title: "  Book flights  ",
      list: RemindersListEntity(list),
      notes: "Use points",
      dueDate: dueDate,
      isFlagged: true,
      priority: .high,
      tags: ["travel plans, #Work", "work"],
      database: database,
      notificationScheduler: .disabled
    )

    _ = try await intent.perform()

    let reminders = try await database.read {
      try Reminder.all.fetchAll($0)
    }
    let tags = try await database.read {
      try Tag.order(by: \.title).fetchAll($0)
    }
    #expect(reminders.count == 1)
    #expect(reminders[0].title == "Book flights")
    #expect(reminders[0].notes == "Use points")
    #expect(reminders[0].dueDate == ReminderDate(dateAndTime: dueDate))
    #expect(reminders[0].isFlagged)
    #expect(reminders[0].priority == .high)
    #expect(reminders[0].remindersListID == list.id)
    #expect(tags.map(\.title) == ["travel plans", "Work"])
  }

  @Test
  func createReminderUsesFirstListWhenNoListIsSpecified() async throws {
    let database = try SQLiteQueue.reminders()
    let second = RemindersList(id: UUID(), position: 1, title: "Second")
    let first = RemindersList(id: UUID(), title: "First")
    try await database.write {
      try RemindersList.insert {
        RemindersList.Draft(second)
        RemindersList.Draft(first)
      }
      .execute($0)
    }

    _ = try await CreateReminderIntent(
      title: "Call home",
      database: database,
      notificationScheduler: .disabled
    )
    .perform()

    let reminder = try await database.read {
      try Reminder.all.fetchOne($0)
    }
    #expect(reminder?.remindersListID == first.id)
  }

  @Test
  func createReminderRequiresAnExistingList() async throws {
    let database = try SQLiteQueue.reminders()
    do {
      _ = try await CreateReminderIntent(
        title: "Call home",
        database: database,
        notificationScheduler: .disabled
      )
      .perform()
      Issue.record("Expected reminder creation to fail without a list")
    } catch {
      #expect(error.localizedDescription == "Create a reminders list before adding a reminder.")
    }
    #expect(
      try await database.read { try Reminder.count().fetchOne($0) } == 0
    )
  }

  @Test
  func completeAndReopenReminderAreIdempotent() async throws {
    let database = try SQLiteQueue.reminders()
    let (list, reminder) = try await insertReminder(in: database)
    let entity = ReminderEntity(
      reminder: reminder,
      remindersList: list
    )

    let complete = CompleteReminderIntent(
      reminder: entity,
      database: database,
      notificationScheduler: .disabled
    )
    _ = try await complete.perform()
    _ = try await complete.perform()
    #expect(try await status(of: reminder.id, in: database) == .completed)

    let reopen = ReopenReminderIntent(
      reminder: entity,
      database: database,
      notificationScheduler: .disabled
    )
    _ = try await reopen.perform()
    _ = try await reopen.perform()
    #expect(try await status(of: reminder.id, in: database) == .incomplete)
  }

  @Test
  func deleteRemindersDeletesOnlyTheSelectedRecords() async throws {
    let database = try SQLiteQueue.reminders()
    let (list, first) = try await insertReminder(in: database, title: "First")
    let (_, second) = try await insertReminder(
      in: database,
      list: list,
      title: "Second"
    )
    let entity = ReminderEntity(
      reminder: first,
      remindersList: list
    )

    _ = try await DeleteRemindersIntent(
      entities: [entity],
      database: database,
      notificationScheduler: .disabled
    )
    .perform()

    let remainingIDs = try await database.read {
      try Reminder.select(\.id).fetchAll($0)
    }
    #expect(remainingIDs == [second.id])
  }

  @Test
  func intentsReconcileNotificationsBeforeReturning() async throws {
    let database = try SQLiteQueue.reminders()
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write {
      try RemindersList.insert { list }.execute($0)
    }
    let center = RecordingReminderNotificationCenter()
    let scheduler = ReminderNotificationScheduler(center: center)

    let result = try await CreateReminderIntent(
      title: "Call home",
      list: RemindersListEntity(list),
      dueDate: Date.distantFuture,
      database: database,
      notificationScheduler: scheduler
    )
    .perform()
    let entity = try #require(result.value)

    #expect(
      await center.requestIdentifiers()
        == [ReminderNotificationIdentifiers.request(for: entity.id)]
    )

    _ = try await CompleteReminderIntent(
      reminder: entity,
      database: database,
      notificationScheduler: scheduler
    )
    .perform()

    #expect(await center.requestIdentifiers().isEmpty)
  }

  private func insertReminder(
    in database: RemindersDatabase,
    list: RemindersList? = nil,
    title: String = "Call home"
  ) async throws -> (RemindersList, Reminder) {
    let list = list ?? RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      remindersListID: list.id,
      title: title
    )
    try await database.write { transaction in
      try RemindersList.upsert { RemindersList.Draft(list) }.execute(transaction)
      try Reminder.insert { Reminder.Draft(reminder) }.execute(transaction)
    }
    return (list, reminder)
  }

  private func status(
    of id: Reminder.ID,
    in database: RemindersDatabase
  ) async throws -> Reminder.Status? {
    try await database.read {
      try Reminder.find(id).select(\.status).fetchOne($0)
    }
  }
}

private extension CreateReminderIntent {
  init(
    title: String,
    list: RemindersListEntity? = nil,
    notes: String? = nil,
    dueDate: Date? = nil,
    isFlagged: Bool = false,
    priority: ReminderIntentPriority? = nil,
    tags: [String]? = nil,
    database: RemindersDatabase,
    notificationScheduler: ReminderNotificationScheduler
  ) {
    self.init(
      title: title,
      list: list,
      notes: notes,
      dueDate: dueDate,
      isFlagged: isFlagged,
      priority: priority,
      tags: tags,
      dependencies: AppDependencyManager()
    )
    $database.wrappedValue = database
    $notificationScheduler.wrappedValue = notificationScheduler
  }
}

private extension CompleteReminderIntent {
  init(
    reminder: ReminderEntity,
    database: RemindersDatabase,
    notificationScheduler: ReminderNotificationScheduler
  ) {
    self.init(reminder: reminder, dependencies: AppDependencyManager())
    $database.wrappedValue = database
    $notificationScheduler.wrappedValue = notificationScheduler
  }
}

private extension ReopenReminderIntent {
  init(
    reminder: ReminderEntity,
    database: RemindersDatabase,
    notificationScheduler: ReminderNotificationScheduler
  ) {
    self.init(reminder: reminder, dependencies: AppDependencyManager())
    $database.wrappedValue = database
    $notificationScheduler.wrappedValue = notificationScheduler
  }
}

private extension DeleteRemindersIntent {
  init(
    entities: [ReminderEntity],
    database: RemindersDatabase,
    notificationScheduler: ReminderNotificationScheduler
  ) {
    self.init(entities: entities, dependencies: AppDependencyManager())
    $database.wrappedValue = database
    $notificationScheduler.wrappedValue = notificationScheduler
  }
}

private actor RecordingReminderNotificationCenter: ReminderNotificationCenter {
  private var requests: [String: ReminderNotificationRequest] = [:]

  func add(_ request: ReminderNotificationRequest) async throws {
    requests[request.identifier] = request
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

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {}

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
    for identifier in identifiers {
      requests[identifier] = nil
    }
  }

  func requestAuthorization() async throws -> Bool {
    true
  }

  func requestIdentifiers() -> [String] {
    requests.keys.sorted()
  }
}
