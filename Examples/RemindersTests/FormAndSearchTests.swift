import Foundation
import RemindersData
import SQLiteOrbit
import SQLiteOrbitTestSupport
import SwiftUI
import Testing

@MainActor
@Suite(.orbitDatabase(try makeTestDatabase()))
struct FormAndSearchTests {
  @Test
  func searchHighlightUsesBoldTextAndABackgroundColor() throws {
    let text = try #require(ReminderRow.highlightedAttributedString("Call **Blob** today"))
    let highlightedRun = try #require(
      text.runs.first {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      }
    )

    #expect(String(text.characters) == "Call Blob today")
    #expect(highlightedRun.backgroundColor != nil)
  }

  @Test
  func listFormCreatesThenEditsAList() async throws {
    let database = OrbitDefaultDatabase.current
    let create = RemindersListFormModel(remindersList: nil)
    create.title = "Personal"
    #expect(await create.save())
    let listID = create.id

    let inserted = try #require(
      await database.read { try RemindersList.find(listID).fetchOne($0) }
    )
    #expect(inserted.title == "Personal")

    let edit = RemindersListFormModel(remindersList: inserted)
    edit.title = "Home"
    #expect(await edit.save())

    let updated = try #require(
      await database.read { try RemindersList.find(listID).fetchOne($0) }
    )
    #expect(updated.title == "Home")
    #expect(try await database.read { try RemindersList.count().fetchOne($0) } == 1)
  }

  @Test
  func reminderFormCreatesTagsAndSearchableText() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write {
      try RemindersList.insert { list }.execute($0)
    }

    let form = ReminderFormModel(remindersList: list)
    form.reminder.title = "Pick up groceries"
    form.reminder.notes = "Milk and coffee"
    form.tagText = "#errands,"
    form.tagTextChanged()
    #expect(form.tagTitles == ["errands"])
    form.tagText = "weekly plan"
    #expect(await form.save())
    let reminderID = form.id

    let tags = try await database.read {
      try Tag.order(by: \.title).fetchAll($0)
    }
    #expect(tags.map(\.title) == ["errands", "weekly plan"])
    #expect(
      try await database.read { try ReminderTag.count().fetchOne($0) } == 2
    )

    let search = SearchRemindersModel()
    await search.loadResults(for: "groceries", showCompleted: false)
    #expect(search.results.map(\.reminder.id) == [reminderID])
    #expect(search.results.first?.highlightedTitle == "Pick up **groceries**")

    await search.loadResults(for: "coffee", showCompleted: false)
    #expect(search.results.first?.highlightedNotes == "Milk and **coffee**")

    await search.loadResults(for: "errands", showCompleted: false)
    #expect(search.results.first?.highlightedTags == "#**errands** #weekly plan")
  }

  @Test
  func reminderFormCompletesAndSuggestsTags() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write {
      try RemindersList.insert { list }.execute($0)
      try Tag.insert {
        Tag.Draft(Tag(title: "home"))
        Tag.Draft(Tag(title: "work"))
        Tag.Draft(Tag(title: "workout"))
      }
      .execute($0)
    }
    let availableTagTitles = try await database.read {
      try Tag.order(by: \.title).select(\.title).fetchAll($0)
    }
    let form = ReminderFormModel(remindersList: list)

    form.tagText = "work, home"
    form.tagTextChanged()
    #expect(form.tagTitles == ["work"])
    #expect(form.tagText == "home")

    form.tagText = "home,"
    form.tagTextChanged()
    #expect(form.tagTitles == ["work", "home"])
    #expect(form.tagText.isEmpty)

    form.tagText = "this is a test,"
    form.tagTextChanged()
    #expect(form.tagTitles == ["work", "home", "this is a test"])
    #expect(form.tagText.isEmpty)

    form.tagText = "wor"
    #expect(form.tagSuggestions(from: availableTagTitles) == ["workout"])

    form.tagSuggestionTapped("workout")
    #expect(form.tagTitles == ["work", "home", "this is a test", "workout"])
    #expect(form.tagText.isEmpty)

    form.removeTagButtonTapped("HOME")
    #expect(form.tagTitles == ["work", "this is a test", "workout"])
  }

  @Test
  func reminderFormPersistsADateWithoutATimeAtTheStartOfDay() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write {
      try RemindersList.insert { list }.execute($0)
    }
    let calendar = Calendar(identifier: .gregorian)
    let dueDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 15, minute: 30))
    )
    let form = ReminderFormModel(remindersList: list)
    form.reminder.title = "Date only"
    form.dueDate = dueDate
    form.dateToggleTapped()

    #expect(await form.save())
    let reminderID = form.id

    let reminder = try #require(
      await database.read { try Reminder.find(reminderID).fetchOne($0) }
    )
    #expect(reminder.dueDate == Calendar.current.startOfDay(for: dueDate))
  }

  @Test
  func reminderFormDateAndTimeModesMaintainTheirInvariants() throws {
    let list = RemindersList(id: UUID(), title: "Personal")
    let form = ReminderFormModel(remindersList: list)

    #expect(!form.isDateEnabled)
    #expect(!form.isTimeEnabled)

    form.dateOptionButtonTapped()
    #expect(form.isDateEnabled)
    #expect(!form.isTimeEnabled)

    form.dateToggleTapped()
    form.timeToggleTapped()
    #expect(form.isDateEnabled)
    #expect(form.isTimeEnabled)

    form.dateToggleTapped()
    #expect(!form.isDateEnabled)
    #expect(!form.isTimeEnabled)

    form.dateToggleTapped()
    #expect(form.isDateEnabled)
    #expect(!form.isTimeEnabled)
  }

  @Test
  func reminderFormEditsUsingADraftWithoutResettingOtherFields() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(
      id: UUID(),
      dueDate: Date(timeIntervalSince1970: 1_800_000_000),
      isFlagged: true,
      notes: "Original notes",
      position: 42,
      priority: .high,
      remindersListID: list.id,
      status: .completed,
      title: "Original title"
    )
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }

    let form = ReminderFormModel(
      remindersList: list,
      reminder: reminder
    )
    form.reminder.title = "Updated title"
    #expect(await form.save())

    let updated = try #require(
      await database.read { try Reminder.find(reminder.id).fetchOne($0) }
    )
    #expect(updated.title == "Updated title")
    #expect(updated.notes == reminder.notes)
    #expect(updated.isFlagged == reminder.isFlagged)
    #expect(updated.position == reminder.position)
    #expect(updated.priority == reminder.priority)
    #expect(updated.remindersListID == reminder.remindersListID)
    #expect(updated.status == reminder.status)
  }

  @Test
  func persistedSearchSettingIncludesCompletedResults() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert {
        [
          Reminder(id: UUID(), remindersListID: list.id, title: "Call Blob"),
          Reminder(
            id: UUID(),
            remindersListID: list.id,
            status: .completed,
            title: "Email Blob"
          )
        ]
      }
      .execute(transaction)
    }
    @SingleRow(SearchSettings.self) var settings
    try await $settings.update { $0.showCompleted = true }

    let search = SearchRemindersModel()
    await search.loadResults(for: "Blob", showCompleted: settings.showCompleted)

    #expect(search.results.map(\.reminder.title).sorted() == ["Call Blob", "Email Blob"])
  }

  @Test
  func completingReminderWaitsForTheUIGracePeriod() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(id: UUID(), remindersListID: list.id, title: "Call Blob")
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }
    let gate = CompletionDelayGate()
    let model = ReminderRowModel(
      sleep: { _ in try await gate.wait() }
    )

    let completion = try #require(model.completionButtonTapped(reminder))

    #expect(model.isCompletionPending)
    let beforeDelay = try #require(
      await database.read { try Reminder.find(reminder.id).fetchOne($0) }
    )
    #expect(!beforeDelay.isCompleted)

    await gate.open()
    await completion.value

    #expect(!model.isCompletionPending)
    let afterDelay = try #require(
      await database.read { try Reminder.find(reminder.id).fetchOne($0) }
    )
    #expect(afterDelay.isCompleted)
  }

  @Test
  func cancellingPendingCompletionLeavesReminderIncomplete() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(id: UUID(), remindersListID: list.id, title: "Call Blob")
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }
    let gate = CompletionDelayGate()
    let model = ReminderRowModel(
      sleep: { _ in try await gate.wait() }
    )

    let completion = try #require(model.completionButtonTapped(reminder))
    #expect(model.completionButtonTapped(reminder) == nil)
    await gate.open()
    await completion.value

    #expect(!model.isCompletionPending)
    let stored = try #require(
      await database.read { try Reminder.find(reminder.id).fetchOne($0) }
    )
    #expect(!stored.isCompleted)
  }

  @Test
  func reminderRowModelHandlesDetailsFlaggingAndDeletion() async throws {
    let database = OrbitDefaultDatabase.current
    let list = RemindersList(id: UUID(), title: "Personal")
    let reminder = Reminder(id: UUID(), remindersListID: list.id, title: "Call Blob")
    try await database.write { transaction in
      try RemindersList.insert { list }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }
    let model = ReminderRowModel()

    model.detailsButtonTapped(reminder, remindersList: list)
    #expect(model.reminderForm?.reminder == reminder)
    #expect(model.reminderForm?.remindersList == list)

    await model.flagButtonTapped(reminder).value
    let flagged = try #require(
      await database.read { try Reminder.find(reminder.id).fetchOne($0) }
    )
    #expect(flagged.isFlagged)

    await model.deleteButtonTapped(reminder).value
    let deleted = try await database.read { try Reminder.find(reminder.id).fetchOne($0) }
    #expect(deleted == nil)
  }

  @Test
  func reminderRowContextMenuActionsPersistChanges() async throws {
    let database = OrbitDefaultDatabase.current
    let personal = RemindersList(id: UUID(), position: 0, title: "Personal")
    let work = RemindersList(id: UUID(), position: 1, title: "Work")
    let reminder = Reminder(id: UUID(), remindersListID: personal.id, title: "Call Blob")
    try await database.write { transaction in
      try RemindersList.insert { [personal, work] }.execute(transaction)
      try Reminder.insert { reminder }.execute(transaction)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 13))
    )
    let model = ReminderRowModel(
      calendar: calendar,
      now: now
    )

    await model.dueDateButtonTapped(reminder, daysFromToday: 1).value
    await model.moveToListButtonTapped(reminder, remindersList: work).value
    await model.priorityButtonTapped(reminder, priority: .high).value

    let updated = try #require(
      await database.read { try Reminder.find(reminder.id).fetchOne($0) }
    )
    #expect(
      updated.dueDate
        == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    )
    #expect(updated.remindersListID == work.id)
    #expect(updated.priority == .high)

    await model.clearDueDateButtonTapped(updated).value
    await model.priorityButtonTapped(updated, priority: nil).value

    let cleared = try #require(
      await database.read { try Reminder.find(reminder.id).fetchOne($0) }
    )
    #expect(cleared.dueDate == nil)
    #expect(cleared.priority == nil)
  }

  @Test
  func sampleDataPopulatesOnlyABlankDatabase() async throws {
    let database = OrbitDefaultDatabase.current
    let model = RemindersListsModel()
    await model.load()

    await model.seedSampleData()
    await model.seedSampleData()

    let counts = try await database.read { transaction in
      try (
        RemindersList.count().fetchOne(transaction) ?? 0,
        Reminder.count().fetchOne(transaction) ?? 0,
        Tag.count().fetchOne(transaction) ?? 0
      )
    }
    #expect(counts.0 == 2)
    #expect(counts.1 == 3)
    #expect(counts.2 == 2)
  }

  @Test
  func tagParsing() {
    #expect(ReminderFormModel.parseTags("#work, HOME work") == ["work", "HOME work"])
    #expect(
      ReminderFormModel.parseTags("  #one two, #three four ") == ["one two", "three four"]
    )
    #expect(ReminderFormModel.parseTags("#this is a test") == ["this is a test"])
    #expect(ReminderFormModel.parseTags("#work, WORK") == ["work"])
    #expect(ReminderFormModel.parseTags("").isEmpty)
  }
}

private actor CompletionDelayGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var isOpen = false

  func wait() async throws {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func open() {
    isOpen = true
    for continuation in continuations {
      continuation.resume()
    }
    continuations.removeAll()
  }
}
