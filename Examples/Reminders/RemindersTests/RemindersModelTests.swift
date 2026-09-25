import Foundation
import RemindersData
import SQLiteOrbit
import SQLiteOrbitTestSupport
import Synchronization
import Testing

@MainActor
@Suite(.orbitDatabase(try makeTestDatabase()))
struct RemindersModelTests {
  @Test
  func newReminderPresentationUsesTheOnlyList() async throws {
    let list = RemindersList(id: UUID(), title: "Personal")
    try await insertFixture(lists: [list])
    let model = RemindersListsModel()
    await model.load()

    model.newReminderButtonTapped()

    #expect(model.reminderForm?.reminder.remindersListID == list.id)
  }

  @Test
  func newReminderDoesNotPresentTheListFormWhenThereAreNoLists() throws {
    let model = RemindersListsModel()

    model.newReminderButtonTapped()

    #expect(model.reminderForm == nil)
    #expect(model.remindersListForm == nil)
    #expect(model.errorMessage == "Create a list before adding a reminder.")
  }

  @Test
  func listDetailPresentsNewReminderForItsList() throws {
    let list = RemindersList(id: UUID(), title: "Work")
    let model = RemindersDetailModel(detailType: .list(list))

    model.newReminderButtonTapped()

    #expect(model.reminderForm?.reminder.remindersListID == list.id)
    #expect(model.reminderForm?.isNew == true)
  }

  @Test
  func smartListsPresentNewRemindersForTheFirstListExceptCompleted() async throws {
    let database = OrbitDefaultDatabase.current
    let firstList = RemindersList(id: UUID(), position: 0, title: "Personal")
    let secondList = RemindersList(id: UUID(), position: 1, title: "Work")
    try await database.write {
      try RemindersList.insert { [firstList, secondList] }.execute($0)
    }

    let detailTypes: [RemindersDetailType] = [
      .all,
      .flagged,
      .scheduled,
      .tags([Tag(title: "errands")]),
      .today
    ]
    for detailType in detailTypes {
      let model = RemindersDetailModel(detailType: detailType)

      #expect(model.canAddReminder)
      model.newReminderButtonTapped()

      #expect(model.reminderForm?.reminder.remindersListID == firstList.id)
    }

    let completed = RemindersDetailModel(detailType: .completed)
    #expect(!completed.canAddReminder)
    completed.newReminderButtonTapped()
    #expect(completed.reminderForm == nil)
  }

  @Test
  func listDeepLinkOpensTheList() async throws {
    let list = RemindersList(id: UUID(), title: "Work")
    try await insertFixture(lists: [list])
    let model = RemindersNavigationModel()

    await model.open(.list(list.id))

    let detail = try #require(model.path.first)
    guard case .list(let destination) = detail.detailType else {
      Issue.record("Expected the list detail destination")
      return
    }
    #expect(destination.id == list.id)
    #expect(detail.reminderForm == nil)
    #expect(model.errorMessage == nil)
  }

  @Test
  func reminderDeepLinkOpensTheReminderFormFromItsList() async throws {
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      remindersListID: list.id,
      title: "Buy milk"
    )
    try await insertFixture(lists: [list], reminders: [reminder])
    let model = RemindersNavigationModel()

    await model.open(.reminder(reminder.id))

    let detail = try #require(model.path.first)
    guard case .list(let destination) = detail.detailType else {
      Issue.record("Expected the reminder's list detail destination")
      return
    }
    #expect(destination.id == list.id)
    #expect(detail.reminderForm?.reminder.remindersListID == list.id)
    #expect(detail.reminderForm?.id == reminder.id)
    #expect(model.errorMessage == nil)
  }

  @Test
  func staleDeepLinkReportsAnErrorWithoutChangingNavigation() async throws {
    let model = RemindersNavigationModel()
    model.detailButtonTapped(.flagged)
    let originalPath = model.path

    await model.open(.reminder(UUID()))

    #expect(model.path == originalPath)
    #expect(model.errorMessage == "This reminder no longer exists.")
  }

  @Test
  func newReminderQuickActionUsesTheFirstListByPosition() async throws {
    let work = RemindersList(id: UUID(), position: 1, title: "Work")
    let personal = RemindersList(id: UUID(), position: 0, title: "Personal")
    try await insertFixture(lists: [work, personal])
    let model = RemindersNavigationModel()

    await model.open(.newReminder)

    #expect(model.reminderForm?.reminder.remindersListID == personal.id)
    #expect(model.reminderForm?.isNew == true)
    #expect(model.errorMessage == nil)
  }

  @Test
  func listQuickActionUsesTheSelectedList() async throws {
    let personal = RemindersList(id: UUID(), position: 0, title: "Personal")
    let work = RemindersList(id: UUID(), position: 1, title: "Work")
    try await insertFixture(lists: [personal, work])
    let model = RemindersNavigationModel()

    await model.open(.newInList(work.id))

    #expect(model.reminderForm?.reminder.remindersListID == work.id)
    #expect(model.reminderForm?.isNew == true)
    #expect(model.errorMessage == nil)
  }

  @Test
  func newReminderQuickActionWithoutListsReportsAnError() async {
    let model = RemindersNavigationModel()

    await model.open(.newReminder)

    #expect(model.reminderForm == nil)
    #expect(model.errorMessage == "Create a list before adding a reminder.")
  }

  @Test
  func quickActionForDeletedListReportsAnError() async {
    let model = RemindersNavigationModel()

    await model.open(.newInList(UUID()))

    #expect(model.reminderForm == nil)
    #expect(model.errorMessage == "This reminders list no longer exists.")
  }

  @Test
  func dashboardCountsInsertedReminders() async throws {
    let now = Date(timeIntervalSince1970: 1_789_560_000)
    try await OrbitDefaultDatabase.withValue(SQLiteQueue.reminders(now: { now })) {
      let list = RemindersList(id: UUID(), title: "Personal")
      try await insertFixture(
        lists: [list],
        reminders: [
          Reminder(
            id: UUID(),
            dueDate: ReminderDate(date: now),
            remindersListID: list.id,
            title: "Today"
          ),
          Reminder(
            id: UUID(),
            isFlagged: true,
            remindersListID: list.id,
            title: "Flagged"
          ),
          Reminder(
            id: UUID(),
            dueDate: ReminderDate(date: now.addingTimeInterval(86_400)),
            remindersListID: list.id,
            title: "Scheduled"
          ),
          Reminder(
            id: UUID(),
            remindersListID: list.id,
            status: .completed,
            title: "Done"
          )
        ]
      )

      let model = RemindersListsModel()
      await model.load()

      #expect(model.stats.allCount == 3)
      #expect(model.stats.flaggedCount == 1)
      #expect(model.stats.scheduledCount == 2)
      #expect(model.stats.todayCount == 1)
      #expect(model.remindersLists.first?.remindersCount == 3)
    }
  }

  @Test
  func dateDependentQueriesUseTheDatabaseClockWhenRefreshed() async throws {
    let today = Date(timeIntervalSince1970: 1_789_560_000)
    let tomorrow = today.addingTimeInterval(86_400)
    let clock = Mutex(today)
    let database = try SQLiteQueue.reminders(now: { clock.withLock { $0 } })
    try await OrbitDefaultDatabase.withValue(database) {
      let list = RemindersList(id: UUID(), title: "Personal")
      try await insertFixture(
        lists: [list],
        reminders: [
          Reminder(
            id: UUID(),
            dueDate: ReminderDate(date: today),
            remindersListID: list.id,
            title: "Day one"
          ),
          Reminder(
            id: UUID(),
            dueDate: ReminderDate(date: tomorrow),
            remindersListID: list.id,
            title: "Day two"
          )
        ]
      )
      let lists = RemindersListsModel()
      let detail = RemindersDetailModel(detailType: .today)
      let search = SearchRemindersModel()
      await lists.load()
      await detail.load()
      await search.loadResults(for: "Day", showCompleted: false)
      #expect(lists.stats.todayCount == 1)
      #expect(detail.reminderRows.map(\.reminder.title) == ["Day one"])
      #expect(search.results.first { $0.reminder.title == "Day one" }?.isPastDue == false)

      clock.withLock { $0 = tomorrow }
      await lists.refreshForCurrentDate()
      await detail.refreshForCurrentDate()
      await search.loadResults(for: "Day", showCompleted: false)
      #expect(lists.stats.todayCount == 1)
      #expect(detail.reminderRows.map(\.reminder.title) == ["Day two"])
      #expect(search.results.first { $0.reminder.title == "Day one" }?.isPastDue == true)
    }
  }

  @Test
  func detailSettingsRoundTripThroughDatabase() async throws {
    let database = OrbitDefaultDatabase.current
    let model = RemindersDetailModel(detailType: .all)
    await model.load()

    #expect(model.ordering == .dueDate)
    #expect(model.showCompleted == false)

    await model.setOrdering(.title)
    await model.toggleShowCompleted()

    let stored = try await database.read {
      try RemindersDetailSettings.find("all").fetchOne($0)
    }
    #expect(stored?.ordering == .title)
    #expect(stored?.showCompleted == true)

    let restored = RemindersDetailModel(detailType: .all)
    #expect(restored.ordering == .title)
    #expect(restored.showCompleted == true)
  }

  @Test
  func detailFiltersCompletedRemindersUntilEnabled() async throws {
    let list = RemindersList(id: UUID(), title: "Work")
    try await insertFixture(
      lists: [list],
      reminders: [
        Reminder(id: UUID(), remindersListID: list.id, title: "Open"),
        Reminder(
          id: UUID(),
          remindersListID: list.id,
          status: .completed,
          title: "Closed"
        )
      ]
    )

    let model = RemindersDetailModel(detailType: .all)
    await model.load()
    #expect(model.reminderRows.map(\.reminder.title) == ["Open"])

    await model.toggleShowCompleted()
    #expect(model.reminderRows.map(\.reminder.title).sorted() == ["Closed", "Open"])
  }

  @Test
  func manualMovePersistsPositionsAndPreference() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Work")
    let reminders = [
      Reminder(id: UUID(), position: 0, remindersListID: list.id, title: "A"),
      Reminder(id: UUID(), position: 1, remindersListID: list.id, title: "B"),
      Reminder(id: UUID(), position: 2, remindersListID: list.id, title: "C")
    ]

    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminders }.execute(transaction)
    }

    let model = RemindersDetailModel(detailType: .list(list))
    await model.load()
    await model.setOrdering(.manual)
    await model.moveReminders(from: IndexSet(integer: 0), to: 3)

    let stored = try await database.read { transaction in
      try Reminder.order(by: \.position).fetchAll(transaction)
    }
    #expect(stored.map(\.title) == ["B", "C", "A"])
    #expect(model.ordering == .manual)

    let settings = try await database.read {
      try RemindersDetailSettings.find("list_\(list.id)").fetchOne($0)
    }
    #expect(settings?.ordering == .manual)
  }

  @Test
  func movingFilteredRemindersUpdatesHiddenPositions() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Work")
    let day = Date(timeIntervalSince1970: 1_789_560_000)
    let reminders = [
      Reminder(
        id: UUID(),
        dueDate: ReminderDate(date: day),
        isFlagged: true,
        position: 2,
        remindersListID: list.id,
        title: "A"
      ),
      Reminder(
        id: UUID(),
        dueDate: ReminderDate(date: day.addingTimeInterval(86_400)),
        position: 0,
        remindersListID: list.id,
        title: "B"
      ),
      Reminder(
        id: UUID(),
        dueDate: ReminderDate(date: day.addingTimeInterval(172_800)),
        isFlagged: true,
        position: 1,
        remindersListID: list.id,
        title: "C"
      )
    ]
    try await insertFixture(lists: [list], reminders: reminders)

    let model = RemindersDetailModel(detailType: .flagged)
    await model.load()
    #expect(model.ordering == .dueDate)
    #expect(model.reminderRows.map(\.reminder.title) == ["A", "C"])

    await model.moveReminders(from: IndexSet(integer: 1), to: 0)

    let stored = try await database.read {
      try Reminder.order(by: \.position).fetchAll($0)
    }
    #expect(stored.map(\.title) == ["C", "A", "B"])
    #expect(stored.map(\.position) == [0, 1, 2])
  }

  @Test
  func movingPastACompletedReminderUpdatesItsPosition() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Work")
    let reminders = [
      Reminder(id: UUID(), position: 0, remindersListID: list.id, title: "A"),
      Reminder(
        id: UUID(),
        position: 1,
        remindersListID: list.id,
        status: .completed,
        title: "B"
      ),
      Reminder(id: UUID(), position: 2, remindersListID: list.id, title: "C")
    ]
    try await insertFixture(lists: [list], reminders: reminders)

    let model = RemindersDetailModel(detailType: .list(list))
    await model.load()
    await model.setOrdering(.manual)
    #expect(model.reminderRows.map(\.reminder.title) == ["A", "C"])

    await model.moveReminders(from: IndexSet(integer: 0), to: 2)

    let stored = try await database.read {
      try Reminder.order(by: \.position).fetchAll($0)
    }
    #expect(stored.map(\.title) == ["B", "C", "A"])
    #expect(stored.map(\.position) == [0, 1, 2])
  }

  @Test
  func movingTheOnlyVisibleReminderIsANoop() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Work")
    let visible = Reminder(
      id: UUID(),
      isFlagged: true,
      position: 0,
      remindersListID: list.id,
      title: "Visible"
    )
    let hidden = Reminder(
      id: UUID(),
      position: 1,
      remindersListID: list.id,
      title: "Hidden"
    )
    try await insertFixture(lists: [list], reminders: [visible, hidden])
    let model = RemindersDetailModel(detailType: .flagged)
    await model.load()

    await model.moveReminders(from: IndexSet(integer: 0), to: 1)

    let stored = try await database.read {
      try Reminder.order(by: \.position).fetchAll($0)
    }
    #expect(stored.map(\.id) == [visible.id, hidden.id])
    #expect(stored.map(\.position) == [0, 1])
    #expect(model.ordering == .dueDate)
  }

  @Test(.timeLimit(.minutes(1)))
  func widgetReloaderRefreshesAfterLocalAndExternalCommits() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let network = InMemoryIPCTransport.Network()
    let path = OrbitDatabasePath.file(directory.appending(path: "reminders.sqlite"))
    let identifier = OrbitDatabaseIdentifier(rawValue: "widget-reload-test")
    let appDatabase = OrbitIPCDatabase(
      writer: try SQLitePool(path: path),
      id: identifier,
      transport: InMemoryIPCTransport(network: network)
    )
    let peerDatabase = OrbitIPCDatabase(
      writer: try SQLitePool(path: path),
      id: identifier,
      transport: InMemoryIPCTransport(network: network)
    )
    try remindersMigrator().migrateBlocking(appDatabase)
    let refreshCount = Mutex(0)
    let reloader = try RemindersWidgetReloader(database: appDatabase) {
      refreshCount.withLock { $0 += 1 }
    }
    appDatabase.delegate = reloader

    let list = RemindersList(id: UUID(), title: "Personal")
    try await appDatabase.write { try RemindersList.insert { list }.execute($0) }
    #expect(refreshCount.withLock { $0 } == 1)

    let reminder = Reminder(
      id: UUID(),
      remindersListID: list.id,
      title: "From a peer"
    )
    try await peerDatabase.write { try Reminder.insert { reminder }.execute($0) }
    for _ in 0..<100 {
      if refreshCount.withLock({ $0 }) == 2 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(refreshCount.withLock { $0 } == 2)
  }
}
