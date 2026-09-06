import SQLiteOrbit
import Testing

@Suite
struct OrbitDatabaseRegionTests {
  @Test
  func schemaNamesAreExplicitAndCaseInsensitive() {
    #expect(SQLiteSchemaName.main == SQLiteSchemaName("MAIN"))
    #expect(SQLiteSchemaName.temp.rawValue == "temp")
    #expect(SQLiteSchemaName("Archive") == "archive")
    #expect(
      OrbitDatabaseRegion(table: "reminders")
        == OrbitDatabaseRegion(table: "reminders", schema: .main)
    )
  }

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
  func setOperationsObeyTheirAlgebraicLaws() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")
    let completed = OrbitDatabaseRegion(column: "isCompleted", in: "reminders")
    let reminders = OrbitDatabaseRegion(table: "reminders")
    let tags = OrbitDatabaseRegion(table: "tags")
    let regions = [
      OrbitDatabaseRegion.empty,
      title,
      completed,
      title.union(completed),
      reminders,
      reminders.subtracting(title),
      tags,
      OrbitDatabaseRegion.fullDatabase.subtracting(reminders),
      OrbitDatabaseRegion.fullDatabase
    ]

    for lhs in regions {
      #expect(lhs.union(lhs) == lhs)
      #expect(lhs.intersection(lhs) == lhs)
      #expect(lhs.symmetricDifference(lhs) == .empty)
      #expect(lhs.subtracting(lhs) == .empty)
      for rhs in regions {
        #expect(lhs.union(rhs) == rhs.union(lhs))
        #expect(lhs.intersection(rhs) == rhs.intersection(lhs))
        #expect(lhs.symmetricDifference(rhs) == rhs.symmetricDifference(lhs))
        #expect(lhs.subtracting(rhs).intersection(rhs) == .empty)
        #expect(lhs.subtracting(rhs).union(lhs.intersection(rhs)) == lhs)
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
  func setAlgebraRepresentsFiniteExclusions() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")
    let completed = OrbitDatabaseRegion(column: "isCompleted", in: "reminders")
    let reminders = OrbitDatabaseRegion(table: "reminders")
    let tags = OrbitDatabaseRegion(table: "tags")

    let remindersExceptTitle = reminders.subtracting(title)
    #expect(!remindersExceptTitle.overlaps(title))
    #expect(remindersExceptTitle.contains(completed))
    #expect(remindersExceptTitle.union(title) == reminders)
    #expect(reminders.symmetricDifference(title) == remindersExceptTitle)

    let databaseExceptReminders = OrbitDatabaseRegion.fullDatabase.subtracting(reminders)
    #expect(!databaseExceptReminders.overlaps(reminders))
    #expect(databaseExceptReminders.contains(tags))
    #expect(databaseExceptReminders.union(reminders) == .fullDatabase)
    #expect(
      OrbitDatabaseRegion.fullDatabase.symmetricDifference(reminders)
        == databaseExceptReminders
    )
  }

  @Test
  func supportsTheSetAlgebraProtocolSurface() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")
    let completed = OrbitDatabaseRegion(column: "isCompleted", in: "reminders")
    let both = title.union(completed)

    let literal: OrbitDatabaseRegion = [title, completed]
    #expect(literal == both)
    #expect(unionThroughSetAlgebra(title, completed) == both)

    var region = OrbitDatabaseRegion.empty
    let insertion = region.insert(title)
    #expect(insertion.inserted)
    #expect(insertion.memberAfterInsert == title)
    #expect(region == title)
    #expect(!region.insert(title).inserted)

    #expect(region.update(with: both) == title)
    #expect(region == both)
    #expect(region.remove(title) == title)
    #expect(region == completed)
    #expect(region.remove(title) == nil)
  }

  @Test
  func subsetRelationshipsIncludeFiniteExclusions() {
    let title = OrbitDatabaseRegion(column: "title", in: "reminders")
    let completed = OrbitDatabaseRegion(column: "isCompleted", in: "reminders")
    let both = title.union(completed)
    let reminders = OrbitDatabaseRegion(table: "reminders")
    let remindersExceptTitle = reminders.subtracting(title)
    let tags = OrbitDatabaseRegion(table: "tags")
    let databaseExceptReminders = OrbitDatabaseRegion.fullDatabase.subtracting(reminders)
    let regions = [
      OrbitDatabaseRegion.empty,
      title,
      completed,
      both,
      remindersExceptTitle,
      reminders,
      tags,
      databaseExceptReminders,
      OrbitDatabaseRegion.fullDatabase
    ]

    #expect(OrbitDatabaseRegion.empty.isSubset(of: title))
    #expect(title.isSubset(of: both))
    #expect(title.isStrictSubset(of: reminders))
    #expect(!title.isStrictSubset(of: title))
    #expect(completed.isSubset(of: remindersExceptTitle))
    #expect(!title.isSubset(of: remindersExceptTitle))
    #expect(remindersExceptTitle.isStrictSubset(of: reminders))
    #expect(tags.isSubset(of: databaseExceptReminders))
    #expect(databaseExceptReminders.isStrictSubset(of: .fullDatabase))
    #expect(!reminders.isSubset(of: databaseExceptReminders))

    for lhs in regions {
      for rhs in regions {
        #expect(lhs.isSubset(of: rhs) == rhs.contains(lhs))
        #expect(lhs.isSuperset(of: rhs) == lhs.contains(rhs))
        #expect(lhs.isStrictSubset(of: rhs) == (lhs.isSubset(of: rhs) && lhs != rhs))
        #expect(lhs.isStrictSuperset(of: rhs) == (lhs.isSuperset(of: rhs) && lhs != rhs))
        #expect(lhs.isDisjoint(with: rhs) == !lhs.overlaps(rhs))
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

    var symmetricDifference = title
    symmetricDifference.formSymmetricDifference(completed)
    #expect(symmetricDifference == union)

    var subtraction = union
    subtraction.subtract(title)
    #expect(subtraction == completed)
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

  private func unionThroughSetAlgebra<Region: SetAlgebra>(
    _ lhs: Region,
    _ rhs: Region
  ) -> Region {
    lhs.union(rhs)
  }
}
