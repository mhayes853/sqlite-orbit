import Foundation
import SQLiteOrbit
import Testing

@testable import RemindersFeature

@MainActor
@Suite
struct FormAndSearchTests {
  @Test
  func listFormCreatesThenEditsAList() async throws {
    let database = try makeTestDatabase()
    let create = RemindersListFormModel(database: database, remindersList: nil)
    create.title = "Personal"
    #expect(await create.save())
    let listID = create.id

    let inserted = try #require(
      await database.read { try RemindersList.find(listID).fetchOne($0) }
    )
    #expect(inserted.title == "Personal")

    let edit = RemindersListFormModel(database: database, remindersList: inserted)
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
    let database = try makeTestDatabase()
    let list = RemindersList(id: UUID(), title: "Personal")
    try await database.write {
      try RemindersList.insert { list }.execute($0)
    }

    let form = ReminderFormModel(database: database, remindersList: list)
    form.title = "Pick up groceries"
    form.notes = "Milk and coffee"
    form.tagText = "#errands, weekly errands"
    #expect(await form.save())
    let reminderID = form.id

    let tags = try await database.read {
      try Tag.order(by: \.title).fetchAll($0)
    }
    #expect(tags.map(\.title) == ["errands", "weekly"])
    #expect(
      try await database.read { try ReminderTag.count().fetchOne($0) } == 2
    )

    let search = SearchRemindersModel(database: database)
    await search.loadResults(for: "groceries")
    #expect(search.results.map(\.reminder.id) == [reminderID])
  }

  @Test
  func sampleDataPopulatesOnlyABlankDatabase() async throws {
    let database = try makeTestDatabase()
    let model = RemindersListsModel(database: database)
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
    #expect(ReminderFormModel.parseTags("#work, HOME work") == ["work", "HOME"])
    #expect(ReminderFormModel.parseTags("  #one   #two ") == ["one", "two"])
    #expect(ReminderFormModel.parseTags("").isEmpty)
  }
}
