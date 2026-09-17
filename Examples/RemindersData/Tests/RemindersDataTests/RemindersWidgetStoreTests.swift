import Foundation
import SQLiteOrbit
import Testing

@testable import RemindersData

@Suite
struct RemindersWidgetStoreTests {
  @Test
  func recentRemindersAreNewestFirstAndIncomplete() async throws {
    let database = try makeEphemeralDatabase()
    let store = RemindersWidgetStore(database: database)
    let list = RemindersList(id: UUID(), title: "Personal")
    let older = Reminder(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 1),
      remindersListID: list.id,
      title: "Older"
    )
    let newest = Reminder(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 3),
      remindersListID: list.id,
      title: "Newest"
    )
    let completed = Reminder(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 4),
      remindersListID: list.id,
      status: .completed,
      title: "Completed"
    )

    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { [older, newest, completed] }.execute(transaction)
    }

    let reminders = try await store.recentReminders(limit: 2)

    #expect(reminders.map(\.title) == ["Newest", "Older"])
  }

  @Test
  func completingReminderIsIdempotent() async throws {
    let database = try makeEphemeralDatabase()
    let store = RemindersWidgetStore(database: database)
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      remindersListID: list.id,
      title: "Buy milk"
    )

    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }

    try await store.completeReminder(id: reminder.id)
    try await store.completeReminder(id: reminder.id)

    let persisted = try await database.read { transaction in
      try Reminder.find(reminder.id).fetchOne(transaction)
    }
    #expect(persisted?.status == .completed)
    #expect(try await store.recentReminders(limit: 8).isEmpty)
  }

  @Test
  func widgetWriteRefreshesAnObservingAppProcess() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let network = InMemoryIPCTransport.Network()
    let path = OrbitDatabasePath.file(directory.appending(path: "reminders.sqlite"))
    let identifier = OrbitDatabaseIdentifier(rawValue: "reminders-widget-test")
    let appDatabase = OrbitIPCDatabase(
      writer: try SQLitePool(path: path),
      id: identifier,
      transport: InMemoryIPCTransport(network: network)
    )
    let widgetDatabase = OrbitIPCDatabase(
      writer: try SQLitePool(path: path),
      id: identifier,
      transport: InMemoryIPCTransport(network: network)
    )
    try remindersMigrator().migrateBlocking(appDatabase)

    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      remindersListID: list.id,
      title: "Buy milk"
    )
    try await appDatabase.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }

    let observation = OrbitValueObservation<[WidgetReminder]>.trackingAll(
      WidgetReminder.recent(limit: RemindersWidgetConfiguration.maximumReminderCount)
    )
    var values = observation.values(in: appDatabase).makeAsyncIterator()
    #expect(try await values.next()?.map(\.title) == ["Buy milk"])

    try await RemindersWidgetStore(database: widgetDatabase).completeReminder(id: reminder.id)

    #expect(try await values.next()?.isEmpty == true)
  }
}
