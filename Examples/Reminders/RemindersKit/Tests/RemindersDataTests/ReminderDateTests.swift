import Foundation
import SQLiteOrbit
import Testing

@testable import RemindersData

struct ReminderDateTests {
  @Test(arguments: [(nil, nil, "2026-09-19"), (14, 30, "2026-09-19T14:30")])
  func roundTripsThroughItsDatabaseRepresentation(
    hour: Int?,
    minute: Int?,
    rawValue: String
  ) throws {
    let reminderDate = try #require(
      ReminderDate(
        components: DateComponents(
          year: 2026,
          month: 9,
          day: 19,
          hour: hour,
          minute: minute
        )
      )
    )

    #expect(reminderDate.rawValue == rawValue)
    #expect(ReminderDate(rawValue: reminderDate.rawValue) == reminderDate)
    #expect(reminderDate.isAllDay == (hour == nil))
  }

  @Test
  func partialComponentsAndMalformedRawValuesAreRejected() {
    #expect(
      ReminderDate(
        components: DateComponents(
          year: 2026,
          month: 9,
          day: 19,
          hour: 14
        )
      ) == nil
    )
    #expect(ReminderDate(rawValue: "2026-9-19") == nil)
  }

  @Test
  func resolvesComponentsInTheSuppliedCalendar() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: -7 * 60 * 60))
    let reminderDate = try #require(ReminderDate(rawValue: "2026-09-19T14:30"))
    let date = try #require(reminderDate.date(in: calendar))

    #expect(
      calendar.dateComponents(
        [.year, .month, .day, .hour, .minute],
        from: date
      ) == reminderDate.components
    )
  }

  @Test
  func migratesExistingDatesAndTimeInclusion() async throws {
    let database = try SQLiteQueue(path: .memory)
    let migrator = remindersMigrator()
    try await migrator.migrate(database, upTo: "Add reminder time inclusion")

    let listID = UUID()
    let allDayID = UUID()
    let timedID = UUID()
    try await database.write { transaction in
      try transaction.execute(
        """
        INSERT INTO "remindersLists" ("id", "title")
        VALUES ('\(listID)', 'Personal')
        """
      )
      try transaction.execute(
        """
        INSERT INTO "reminders" (
          "id", "dueDate", "includesTime", "remindersListID", "title"
        ) VALUES
          ('\(allDayID)', '2026-09-19 12:00:00.000', 0, '\(listID)', 'All day'),
          ('\(timedID)', '2026-09-19 14:30:00.000', 1, '\(listID)', 'Timed')
        """
      )
    }

    try await migrator.migrate(database)

    let reminders = try await database.read {
      try Reminder.order(by: \.title).fetchAll($0)
    }
    #expect(reminders.map(\.dueDate?.isAllDay) == [true, false])
    #expect(reminders.allSatisfy { $0.dueDate != nil })
  }
}
