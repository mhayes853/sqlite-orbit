import AppIntents
import Foundation
import RemindersData
import RemindersNotifications
import SQLiteOrbit
import Testing
import UserNotifications

struct ReminderIntentTests {
  @Test
  func createReminderPersistsAllDetailsAndExplicitTags() async throws {
    let database = try SQLiteQueue.reminders()
    let dependencies = AppDependencyManager()
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
      dependencies: dependencies
    )
    intent.$database.wrappedValue = database
    intent.$notificationScheduler.wrappedValue = .disabled

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
    let dependencies = AppDependencyManager()
    let second = RemindersList(id: UUID(), position: 1, title: "Second")
    let first = RemindersList(id: UUID(), title: "First")
    try await database.write {
      try RemindersList.insert {
        RemindersList.Draft(second)
        RemindersList.Draft(first)
      }
      .execute($0)
    }

    let intent = CreateReminderIntent(
      title: "Call home",
      dependencies: dependencies
    )
    intent.$database.wrappedValue = database
    intent.$notificationScheduler.wrappedValue = .disabled
    _ = try await intent.perform()

    let reminder = try await database.read {
      try Reminder.all.fetchOne($0)
    }
    #expect(reminder?.remindersListID == first.id)
  }

  @Test
  func createReminderIntentAppendsAfterADeletion() async throws {
    let database = try SQLiteQueue.reminders()
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminders = (0...2).map {
      Reminder(
        id: UUID(),
        position: $0,
        remindersListID: list.id,
        title: "Reminder \($0)"
      )
    }
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminders }.execute(transaction)
      try Reminder.delete(reminders[0]).execute(transaction)
    }

    let intent = CreateReminderIntent(
      title: "New",
      list: RemindersListEntity(list),
      dependencies: AppDependencyManager()
    )
    intent.$database.wrappedValue = database
    intent.$notificationScheduler.wrappedValue = .disabled
    _ = try await intent.perform()

    let positions = try await database.read {
      try Reminder.order(by: \.position).select(\.position).fetchAll($0)
    }
    #expect(positions == [1, 2, 3])
  }

  @Test
  func createReminderRequiresAnExistingList() async throws {
    let database = try SQLiteQueue.reminders()
    let dependencies = AppDependencyManager()
    let intent = CreateReminderIntent(
      title: "Call home",
      dependencies: dependencies
    )
    intent.$database.wrappedValue = database
    intent.$notificationScheduler.wrappedValue = .disabled
    do {
      _ = try await intent.perform()
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
    let dependencies = AppDependencyManager()
    let (list, reminder) = try await insertReminder(in: database)
    let entity = ReminderEntity(
      reminder: reminder,
      remindersList: list
    )

    let complete = CompleteReminderIntent(
      reminder: entity,
      dependencies: dependencies
    )
    complete.$database.wrappedValue = database
    complete.$notificationScheduler.wrappedValue = .disabled
    _ = try await complete.perform()
    _ = try await complete.perform()
    #expect(try await status(of: reminder.id, in: database) == .completed)

    let reopen = ReopenReminderIntent(
      reminder: entity,
      dependencies: dependencies
    )
    reopen.$database.wrappedValue = database
    reopen.$notificationScheduler.wrappedValue = .disabled
    _ = try await reopen.perform()
    _ = try await reopen.perform()
    #expect(try await status(of: reminder.id, in: database) == .incomplete)
  }

  @Test
  func completeReminderUsesTheDefaultDatabase() async throws {
    let database = try SQLiteQueue.reminders()
    let (list, reminder) = try await insertReminder(in: database)

    try await OrbitDefaultDatabase.withValue(database) {
      let intent = CompleteReminderIntent(
        reminder: ReminderEntity(reminder: reminder, remindersList: list)
      )
      intent.$notificationScheduler.wrappedValue = .disabled
      _ = try await intent.callAsFunction(donate: false)
    }

    #expect(try await status(of: reminder.id, in: database) == .completed)
  }

  @Test
  func deleteRemindersDeletesOnlyTheSelectedRecords() async throws {
    let database = try SQLiteQueue.reminders()
    let dependencies = AppDependencyManager()
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

    let intent = DeleteRemindersIntent(
      entities: [entity],
      dependencies: dependencies
    )
    intent.$database.wrappedValue = database
    intent.$notificationScheduler.wrappedValue = .disabled
    _ = try await intent.perform()

    let remainingIDs = try await database.read {
      try Reminder.select(\.id).fetchAll($0)
    }
    #expect(remainingIDs == [second.id])
  }

  @Test
  func intentsReconcileNotificationsBeforeReturning() async throws {
    let database = try SQLiteQueue.reminders()
    let dependencies = AppDependencyManager()
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write {
      try RemindersList.insert { list }.execute($0)
    }
    let center = RecordingReminderNotificationCenter()
    let scheduler = ReminderNotificationScheduler(center: center)

    let create = CreateReminderIntent(
      title: "Call home",
      list: RemindersListEntity(list),
      dueDate: Date.distantFuture,
      dependencies: dependencies
    )
    create.$database.wrappedValue = database
    create.$notificationScheduler.wrappedValue = scheduler
    let result = try await create.perform()
    let entity = try #require(result.value)

    #expect(
      await center.requestIdentifiers()
        == [ReminderNotificationIdentifiers.request(for: entity.id)]
    )

    let complete = CompleteReminderIntent(
      reminder: entity,
      dependencies: dependencies
    )
    complete.$database.wrappedValue = database
    complete.$notificationScheduler.wrappedValue = scheduler
    _ = try await complete.perform()

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
