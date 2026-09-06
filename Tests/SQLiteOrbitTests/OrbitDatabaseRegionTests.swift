import SQLiteOrbit
import Testing

@Suite
struct OrbitDatabaseRegionTests {
  @Test
  func emptyAndFullDatabaseAreAlgebraicBounds() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")

    #expect(OrbitDatabaseRegion.empty.isEmpty)
    #expect(!OrbitDatabaseRegion.empty.isFullDatabase)
    #expect(!OrbitDatabaseRegion.fullDatabase.isEmpty)
    #expect(OrbitDatabaseRegion.fullDatabase.isFullDatabase)
    #expect(title.union(.empty) == title)
    #expect(title.union(.fullDatabase) == .fullDatabase)
    #expect(title.intersection(.empty) == .empty)
    #expect(title.intersection(.fullDatabase) == title)
  }

  @Test
  func columnsWithinATableNormalizeAndCombine() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")
    let completed = OrbitDatabaseRegion(column: "isCompleted", in: "reminders")
    let both = OrbitDatabaseRegion(
      columns: ["title", "isCompleted", "TITLE"],
      in: "REMINDERS"
    )

    #expect(title.union(completed) == both)
    #expect(both.intersection(title) == title)
    #expect(title.intersection(completed) == .empty)
    #expect(both.contains(title))
    #expect(!title.contains(both))
    #expect(title.overlaps(both))
    #expect(!title.overlaps(completed))
    #expect(Set([title, OrbitDatabaseRegion(column: "TITLE", in: "REMINDERS")]).count == 1)
  }

  @Test
  func unionAndIntersectionObeyTheirAlgebraicLaws() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")
    let completed = OrbitDatabaseRegion(column: "isCompleted", in: "reminders")
    let tags = OrbitDatabaseRegion(table: "tags")
    let regions = [
      OrbitDatabaseRegion.empty,
      title,
      completed,
      title.union(completed),
      tags,
      OrbitDatabaseRegion.fullDatabase
    ]

    for lhs in regions {
      #expect(lhs.union(lhs) == lhs)
      #expect(lhs.intersection(lhs) == lhs)
      for rhs in regions {
        #expect(lhs.union(rhs) == rhs.union(lhs))
        #expect(lhs.intersection(rhs) == rhs.intersection(lhs))
        for third in regions {
          #expect(lhs.union(rhs.union(third)) == lhs.union(rhs).union(third))
          #expect(
            lhs.intersection(rhs.intersection(third)) == lhs.intersection(rhs).intersection(third)
          )
          #expect(
            lhs.intersection(rhs.union(third))
              == lhs.intersection(rhs).union(lhs.intersection(third))
          )
        }
      }
    }
  }

  @Test
  func aTableBasisAbsorbsItsColumnBases() {
    let reminders = OrbitDatabaseRegion(table: "reminders")
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")

    #expect(reminders.union(title) == reminders)
    #expect(reminders.intersection(title) == title)
    #expect(reminders.contains(title))
    #expect(!title.contains(reminders))
  }

  @Test
  func distinctTablesAndSchemasDoNotOverlap() {
    let reminders = OrbitDatabaseRegion(table: "reminders")
    let tags = OrbitDatabaseRegion(table: "tags")
    let auxiliaryReminders = OrbitDatabaseRegion(table: "reminders", schema: "auxiliary")

    #expect(reminders.intersection(tags) == .empty)
    #expect(reminders.intersection(auxiliaryReminders) == .empty)
    #expect(!reminders.overlaps(tags))
    #expect(!reminders.overlaps(auxiliaryReminders))
  }

  @Test
  func anEmptyColumnSequenceIsTheEmptyRegion() {
    #expect(OrbitDatabaseRegion(columns: [String](), in: "reminders") == .empty)
  }

  @Test
  func mutatingAlgebraMatchesValueAlgebra() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")
    let completed = OrbitDatabaseRegion(column: "isCompleted", in: "reminders")

    var union = title
    union.formUnion(completed)
    #expect(union == title.union(completed))

    var intersection = union
    intersection.formIntersection(title)
    #expect(intersection == title)
  }

  @Test
  func typedTablesAndInstancesProduceTheirTableRegion() {
    let reminder = Reminder(id: 1, title: "One", isCompleted: false)
    let expected = OrbitDatabaseRegion(table: "reminders")

    #expect(OrbitDatabaseRegion(Reminder.self) == expected)
    #expect(Reminder.databaseRegion == expected)
    #expect(reminder.databaseRegion == expected)
  }

  @Test
  func typedColumnsProduceColumnRegions() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")
    let completed = OrbitDatabaseRegion(column: "isCompleted", in: "reminders")

    #expect(OrbitDatabaseRegion(Reminder.title) == title)
    #expect(Reminder.title.databaseRegion == title)
    #expect(Reminder.databaseRegion(\.title) == title)
    #expect(Reminder.databaseRegion { $0.title } == title)
    #expect(
      Reminder.databaseRegion { ($0.title, $0.isCompleted) }
        == title.union(completed)
    )
  }

  @Test
  func typedTablesPreserveTheirSchema() {
    let expected = OrbitDatabaseRegion(table: "items", schema: "archive")

    #expect(OrbitDatabaseRegion(ArchivedItem.self) == expected)
    #expect(ArchivedItem.databaseRegion == expected)
    #expect(
      ArchivedItem.databaseRegion(\.name)
        == OrbitDatabaseRegion(column: "name", in: "items", schema: "archive")
    )
  }

  @Table("reminders")
  struct Reminder: Equatable, Sendable {
    let id: Int
    var title: String
    var isCompleted: Bool
  }

  @Table("items", schema: "archive")
  struct ArchivedItem: Equatable, Sendable {
    let id: Int
    var name: String
  }
}
