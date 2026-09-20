import Foundation
import RemindersData
import SQLiteOrbit
import SQLiteOrbitTestSupport
import Testing

@MainActor
@Suite(.orbitDatabase(try makeTestDatabase()))
struct RemindersModelTests {
  @Test
  func newReminderPresentationUsesTheFirstInsertedList() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write {
      try RemindersList.insert { list }.execute($0)
    }
    let model = RemindersListsModel()
    await model.load()

    model.newReminderButtonTapped()

    guard case .reminder(let presentedList) = model.presentedSheet else {
      Issue.record("Expected the reminder form to be presented")
      return
    }
    #expect(presentedList.id == list.id)
  }

  @Test
  func newReminderDoesNotPresentTheListFormWhenThereAreNoLists() throws {
    let model = RemindersListsModel()

    model.newReminderButtonTapped()

    #expect(model.presentedSheet == nil)
    #expect(model.errorMessage == "Create a list before adding a reminder.")
  }

  @Test
  func listDetailPresentsNewReminderForItsList() throws {
    let list = RemindersList(id: UUID(), title: "Work")
    let model = RemindersDetailModel(detailType: .list(list))

    model.newReminderButtonTapped()

    #expect(model.reminderForm?.remindersList.id == list.id)
    #expect(model.reminderForm?.reminder == nil)
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

      #expect(model.reminderForm?.remindersList.id == firstList.id)
    }

    let completed = RemindersDetailModel(detailType: .completed)
    #expect(!completed.canAddReminder)
    completed.newReminderButtonTapped()
    #expect(completed.reminderForm == nil)
  }

  @Test
  func showingSmartListReplacesTheNavigationPath() throws {
    let model = RemindersNavigationModel()

    model.show(.flagged)

    #expect(model.path == [.flagged])
    #expect(model.reminderForm == nil)
  }

  @Test
  func listDeepLinkOpensTheList() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Work")
    try await database.write {
      try RemindersList.insert { list }.execute($0)
    }
    let model = RemindersNavigationModel()

    await model.open(.list(list.id))

    guard case .list(let destination)? = model.path.first else {
      Issue.record("Expected the list detail destination")
      return
    }
    #expect(destination.id == list.id)
    #expect(model.reminderForm == nil)
    #expect(model.errorMessage == nil)
  }

  @Test
  func reminderDeepLinkOpensTheReminderFormFromItsList() async throws {
    let database = OrbitDefaultDatabase.current
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
    let model = RemindersNavigationModel()

    await model.open(.reminder(reminder.id))

    guard case .list(let destination)? = model.path.first else {
      Issue.record("Expected the reminder's list detail destination")
      return
    }
    #expect(destination.id == list.id)
    #expect(model.reminderForm?.remindersList.id == list.id)
    #expect(model.reminderForm?.reminder?.id == reminder.id)
    #expect(model.errorMessage == nil)
  }

  @Test
  func staleDeepLinkReportsAnErrorWithoutChangingNavigation() async throws {
    let model = RemindersNavigationModel()
    model.show(.flagged)

    await model.open(.reminder(UUID()))

    #expect(model.path == [.flagged])
    #expect(model.reminderForm == nil)
    #expect(model.errorMessage == "This reminder no longer exists.")
  }

  @Test
  func dashboardCountsInsertedReminders() async throws {
    let database = OrbitDefaultDatabase.current
    let listID = UUID()
    let now = Date(timeIntervalSince1970: 1_789_560_000)

    try await database.write { transaction in
      try RemindersList.insert {
        RemindersList(id: listID, title: "Personal")
      }
      .execute(transaction)
      try Reminder.insert {
        Reminder(
          id: UUID(),
          dueDate: ReminderDate(date: now),
          remindersListID: listID,
          title: "Today"
        )
      }
      .execute(transaction)
      try Reminder.insert {
        Reminder(
          id: UUID(),
          isFlagged: true,
          remindersListID: listID,
          title: "Flagged"
        )
      }
      .execute(transaction)
      try Reminder.insert {
        Reminder(
          id: UUID(),
          dueDate: ReminderDate(date: now.addingTimeInterval(86_400)),
          remindersListID: listID,
          title: "Scheduled"
        )
      }
      .execute(transaction)
      try Reminder.insert {
        Reminder(
          id: UUID(),
          remindersListID: listID,
          status: .completed,
          title: "Done"
        )
      }
      .execute(transaction)
    }

    let model = RemindersListsModel(now: now)
    await model.load()

    #expect(model.stats.allCount == 3)
    #expect(model.stats.flaggedCount == 1)
    #expect(model.stats.scheduledCount == 2)
    #expect(model.stats.todayCount == 1)
    #expect(model.remindersLists.first?.remindersCount == 3)
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
    let database = OrbitDefaultDatabase.current
    let listID = UUID()

    try await database.write { transaction in
      try RemindersList.insert {
        RemindersList(id: listID, title: "Work")
      }
      .execute(transaction)
      try Reminder.insert {
        Reminder(id: UUID(), remindersListID: listID, title: "Open")
      }
      .execute(transaction)
      try Reminder.insert {
        Reminder(
          id: UUID(),
          remindersListID: listID,
          status: .completed,
          title: "Closed"
        )
      }
      .execute(transaction)
    }

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
      for reminder in reminders {
        try Reminder.insert { reminder }.execute(transaction)
      }
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
}
