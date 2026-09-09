#if BuiltInSQLite
  import Testing

  #if canImport(Observation)
    import Observation
  #endif

  @testable import SQLiteOrbit

  // The suite is serialized because a few of its tests set the process-wide default database,
  // which every other test in it would otherwise see.
  @Suite(.serialized)
  struct FetchPropertyTests {
    @Test
    func fetchAllIsPopulatedByItsFirstRead() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders

      #expect(reminders.map(\.title) == ["Milk", "Eggs"])
      #expect($reminders.loadError == nil)
      #expect(!$reminders.isLoading)
    }

    @Test
    func fetchAllWithoutAQueryFetchesEveryRow() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(database: database) var reminders: [Reminder]

      #expect(reminders.map(\.title) == ["Milk"])
    }

    @Test
    func fetchAllRefetchesAfterACommittedWrite() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders
      #expect(reminders.count == 1)

      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }

      try await waitUntil { reminders.map(\.title) == ["Milk", "Eggs"] }
    }

    @Test
    func fetchAllTracksTheRegionsItRead() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders
      #expect(reminders.count == 1)

      // Writing to a table the query never read must not produce a value.
      try await database.write { transaction in
        try transaction.execute(Tag.insert { Tag.Draft(name: "home") })
      }
      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }

      try await waitUntil { reminders.count == 2 }
    }

    @Test
    func fetchOneObservesAnAggregate() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchOne(Reminder.all.count(), database: database) var count = 0
      #expect(count == 1)

      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }

      try await waitUntil { count == 2 }
    }

    @Test
    func fetchOneReportsAMissingRowAndKeepsItsValue() async throws {
      let database = try await remindersDatabase()
      let placeholder = Reminder(id: 0, title: "", isCompleted: false)

      @FetchOne(Reminder.find(1), database: database) var reminder = placeholder

      #expect(reminder == placeholder)
      #expect($reminder.loadError is OrbitDatabaseRecordNotFoundError)
    }

    @Test
    func fetchOneOfAnOptionalIsNilWhenTheRowIsMissing() async throws {
      let database = try await remindersDatabase()

      @FetchOne(Reminder.find(1), database: database) var reminder: Reminder?

      #expect(reminder == nil)
      #expect($reminder.loadError == nil)

      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Milk") })
      }

      try await waitUntil { reminder?.title == "Milk" }
    }

    @Test
    func fetchRunsARequestOfSeveralQueriesInOneTransaction() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @Fetch(RemindersOverview(), database: database) var overview = RemindersOverview.Value()

      #expect(overview == RemindersOverview.Value(count: 2, titles: ["Milk", "Eggs"]))

      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Bread") })
      }

      try await waitUntil { overview.count == 3 && overview.titles.last == "Bread" }
    }

    @Test
    func loadReplacesTheObservedQuery() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders
      #expect(reminders.count == 2)

      try await $reminders.load(
        Reminder.where { $0.title.eq("Eggs") },
        database: database
      )
      #expect(reminders.map(\.title) == ["Eggs"])

      // The replacement query is what is observed from now on.
      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }
      try await waitUntil { reminders.count == 2 }

      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Bread") })
      }
      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }
      try await waitUntil { reminders.count == 3 }
    }

    @Test
    func loadOfARequestReplacesWhatIsObserved() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @Fetch(TitleSearch(term: "Milk"), database: database) var titles = [String]()
      #expect(titles == ["Milk"])

      try await $titles.load(TitleSearch(term: "Eggs"), database: database)
      #expect(titles == ["Eggs"])
    }

    @Test
    func cancellingTheSubscriptionStopsObservingAndKeepsTheValue() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders
      let subscription = try await $reminders.load(
        Reminder.order(by: \.id),
        database: database
      )
      #expect(reminders.count == 1)

      subscription.cancel()

      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }
      try await Task.sleep(for: .milliseconds(50))

      #expect(reminders.count == 1)
    }

    @Test
    func loadReadsTheQueryAgain() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      // A property with no query never observes, so an explicit load is the only thing that
      // changes it.
      @FetchAll var reminders = [Reminder]()
      #expect(reminders.isEmpty)

      @FetchAll(Reminder.order(by: \.id), database: database) var observed
      try await $observed.load()
      #expect(observed.count == 1)
    }

    @Test
    func theDefaultDatabaseIsUsedWhenNoneIsGiven() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      try await OrbitDefaultDatabase.withValue(database) {
        @FetchAll(Reminder.all) var reminders
        #expect(reminders.count == 1)
      }
    }

    @Test
    func theDefaultDatabaseCanBeSetForTheProcess() async throws {
      let database = try await remindersDatabase(titles: "Milk")
      OrbitDefaultDatabase.set(database)
      defer { OrbitDefaultDatabase.set(nil) }

      @FetchAll(Reminder.all) var reminders

      #expect(reminders.count == 1)
    }

    @Test
    func aMissingDefaultDatabaseIsReportedRatherThanTrapped() async throws {
      @FetchAll(Reminder.all) var reminders

      #expect(reminders.isEmpty)
      #expect($reminders.loadError is OrbitMissingDefaultDatabaseError)
    }

    @Test
    func aMemberIsProjectedAsAReader() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders
      let count = $reminders.count

      #expect(count.wrappedValue == 1)

      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }
      try await waitUntil { count.wrappedValue == 2 }
    }

    @Test
    func assigningAProjectedValueAdoptsItsQuery() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @FetchAll(Reminder.where { $0.title.eq("Milk") }, database: database) var reminders
      @FetchAll(Reminder.order(by: \.id), database: database) var all
      #expect(reminders.count == 1)
      #expect(all.count == 2)

      $reminders = $all
      #expect(reminders.count == 2)

      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Bread") })
      }
      try await waitUntil { reminders.count == 3 }
    }

    @Test
    func aDeferredSchedulerLeavesThePropertyLoading() async throws {
      let database = try await remindersDatabase(titles: "Milk")
      // Deferring by hand rather than with `.mainActor`, whose delivery lands on another thread
      // and can beat the expectations below to the property.
      let scheduler = HeldScheduler()

      @FetchAll(Reminder.all, database: database, scheduler: scheduler) var reminders

      #expect(reminders.isEmpty)
      #expect($reminders.isLoading)

      scheduler.release()
      try await waitUntil { reminders.count == 1 }
      #expect(!$reminders.isLoading)
    }

    @Test
    func aFailedReadKeepsTheValueAndReportsTheError() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(
        #sql("SELECT title FROM missing_table", as: String.self),
        database: database
      )
      var titles

      #expect(titles.isEmpty)
      #expect($titles.loadError is SQLiteError)
    }

    #if canImport(Observation)
      @Test
      func readingInATrackedScopeIsInvalidatedByAWrite() async throws {
        guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
        let database = try await remindersDatabase(titles: "Milk")

        @FetchAll(Reminder.order(by: \.id), database: database) var reminders
        let didChange = Lock(false)

        withObservationTracking {
          _ = reminders
        } onChange: {
          didChange.withLock { $0 = true }
        }
        #expect(!didChange.withLock { $0 })

        try await database.write { transaction in
          try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
        }

        try await waitUntil { didChange.withLock { $0 } }
      }
    #endif

    @Test
    func fetchOneObservesTheRowItWasDeclaredWith() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @FetchOne(database: database) var reminder = Reminder(id: 2, title: "")

      #expect(reminder.title == "Eggs")

      try await database.write { transaction in
        try transaction.execute(
          Reminder.where { $0.id.eq(2) }.update { $0.title = "Bagels" }
        )
      }
      try await waitUntil { reminder.title == "Bagels" }

      // A write to another row leaves it alone.
      try await database.write { transaction in
        try transaction.execute(
          Reminder.where { $0.id.eq(1) }.update { $0.title = "Oat milk" }
        )
      }
      try await Task.sleep(for: .milliseconds(20))
      #expect(reminder.title == "Bagels")
    }

    @Test
    func fetchOneOfAnOptionalTableObservesTheFirstRow() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchOne(database: database) var first: Reminder?

      #expect(first?.title == "Milk")
    }

    @Test
    func fetchAllDecodesASelectionFromAJoin() async throws {
      let database = try await taggedRemindersDatabase()

      @FetchAll(
        Reminder
          .join(Tag.all) { $0.id.eq($1.id) }
          .order { reminder, _ in reminder.title }
          .select { TaggedTitle.Columns(title: $0.title, tag: $1.name) },
        database: database
      )
      var rows

      #expect(rows.map(\.title) == ["Bread", "Eggs", "Milk"])
      #expect(rows.map(\.tag) == ["work", "errands", "home"])
    }

    @Test
    func fetchOneRunsRawSQL() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @FetchOne(
        #sql("SELECT count(*) FROM reminders", as: Int.self),
        database: database
      )
      var count = 0

      #expect(count == 2)

      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Bread") })
      }
      try await waitUntil { count == 3 }
    }

    @Test
    func loadResumesObservingAfterAFailedRead() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(
        #sql("SELECT title FROM notes ORDER BY title", as: String.self),
        database: database
      )
      var titles
      #expect($titles.loadError is SQLiteError)

      try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL)"
        )
        try transaction.execute(Note.insert { Note.Draft(title: "First") })
      }

      try await $titles.load()
      #expect(titles == ["First"])
      #expect($titles.loadError == nil)

      // The retry resumed the observation, so later writes still arrive.
      try await database.write { transaction in
        try transaction.execute(Note.insert { Note.Draft(title: "Second") })
      }
      try await waitUntil { titles == ["First", "Second"] }
    }

    // MARK: - Sections

    @Test
    func sectionsGroupRowsByAnExpression() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        try transaction.execute(
          Reminder.insert {
            Reminder.Draft(title: "Milk", priority: "low")
            Reminder.Draft(title: "Eggs", priority: "high")
            Reminder.Draft(title: "Bread", priority: "low")
          }
        )
      }

      @FetchAll(Reminder.order(by: \.title), sectionBy: \.priority, database: database)
      var reminders  // A key path is the shorthand for `sectionBy: { $0.priority }`.

      #expect(reminders.map(\.title) == ["Eggs", "Bread", "Milk"])
      #expect($reminders.sections.sectionNames == ["high", "low"])
      #expect($reminders.sections[sectionName: "low"]?.map(\.title) == ["Bread", "Milk"])
      #expect($reminders.sections.count == 2)
      #expect($reminders.sections[0].name == "high")
      #expect($reminders.sections[0].map(\.title) == ["Eggs"])
    }

    @Test
    func anUnsectionedPropertyHasOneSectionOfEveryRow() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders

      #expect($reminders.sections.sectionNames == [nil])
      #expect($reminders.sections[0].map(\.title) == ["Milk", "Eggs"])
    }

    @Test
    func anEmptySectionedQueryHasNoSections() async throws {
      let database = try await remindersDatabase()

      @FetchAll(Reminder.all, sectionBy: { $0.priority }, database: database) var reminders

      #expect(reminders.isEmpty)
      #expect($reminders.sections.isEmpty)
    }

    @Test
    func sectionsAreRegroupedAfterAWrite() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        try transaction.execute(
          Reminder.insert { Reminder.Draft(title: "Milk", priority: "low") }
        )
      }

      @FetchAll(
        Reminder.order(by: \.title),
        sectionBy: { $0.priority },
        database: database
      )
      var reminders
      #expect($reminders.sections.sectionNames == ["low"])

      try await database.write { transaction in
        try transaction.execute(
          Reminder.insert { Reminder.Draft(title: "Eggs", priority: "high") }
        )
      }

      try await waitUntil { $reminders.sections.sectionNames == ["high", "low"] }
    }

    @Test
    func sectioningByAnOrderingTermOrdersTheSections() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        try transaction.execute(
          Reminder.insert {
            Reminder.Draft(title: "Milk", priority: "low")
            Reminder.Draft(title: "Eggs", priority: "high")
          }
        )
      }

      @FetchAll(
        Reminder.all,
        sectionBy: { $0.priority.desc() },
        database: database
      )
      var reminders

      #expect($reminders.sections.sectionNames == ["low", "high"])
    }

    @Test
    func aNilSectioningExpressionLeavesOneSection() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")

      @FetchAll(Reminder.all, sectionBy: { _ in nil }, database: database) var reminders

      #expect(reminders.count == 2)
      #expect($reminders.sections.sectionNames == [nil])
    }

    @Test
    func loadingASectionedQueryReplacesTheSections() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        try transaction.execute(
          Reminder.insert {
            Reminder.Draft(title: "Milk", priority: "low")
            Reminder.Draft(title: "Eggs", priority: "high")
          }
        )
      }

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders
      #expect($reminders.sections.sectionNames == [nil])

      try await $reminders.load(
        Reminder.order(by: \.title),
        sectionBy: { $0.priority },
        database: database
      )
      #expect($reminders.sections.sectionNames == ["high", "low"])
      #expect(reminders.map(\.title) == ["Eggs", "Milk"])

      // Loading an unsectioned query puts every row back into one section.
      try await $reminders.load(Reminder.order(by: \.id), database: database)
      #expect($reminders.sections.sectionNames == [nil])
    }

    @Test
    func aSectionKeepsRowsThatComeBackToIt() async throws {
      let database = try await remindersDatabase()
      try await database.write { transaction in
        try transaction.execute(
          Reminder.insert {
            Reminder.Draft(title: "A", priority: "low")
            Reminder.Draft(title: "B", priority: "high")
            Reminder.Draft(title: "C", priority: "low")
          }
        )
      }

      // Ordering by title fights the section order, so "low" is left and returned to.
      @FetchAll(
        Reminder.order(by: \.title),
        sectionBy: { _ in nil },
        database: database
      )
      var reminders
      #expect(reminders.map(\.title) == ["A", "B", "C"])

      @FetchAll(Reminder.order(by: \.title), database: database) var byTitle
      let sections = OrbitFetchSectionCollection(
        elements: byTitle,
        sections: [
          (
            name: "low",
            elements: {
              var indices = OrbitFetchElementIndices(range: 0..<1)
              indices.append(2)
              return indices
            }()
          ),
          (name: "high", elements: OrbitFetchElementIndices(range: 1..<2))
        ]
      )
      #expect(sections[sectionName: "low"]?.map(\.title) == ["A", "C"])
      #expect(sections[sectionName: "high"]?.map(\.title) == ["B"])
    }

    @Test
    func sectionsGroupAJoinedStatementByItsFromTable() async throws {
      let database = try await taggedRemindersDatabase()

      @FetchAll(
        Reminder
          .join(Tag.all) { $0.id.eq($1.id) }
          .order { reminder, _ in reminder.title }
          .select { TaggedTitle.Columns(title: $0.title, tag: $1.name) },
        sectionBy: { reminder in reminder.priority },
        database: database
      )
      var rows

      #expect(rows.map(\.title) == ["Eggs", "Bread", "Milk"])
      #expect($rows.sections.sectionNames == ["high", "low"])
      #expect($rows.sections[sectionName: "low"]?.map(\.tag) == ["work", "home"])
    }

    @Test
    func sectionsGroupAJoinedStatementByAJoinedTable() async throws {
      let database = try await taggedRemindersDatabase()

      @FetchAll(
        Reminder
          .join(Tag.all) { $0.id.eq($1.id) }
          .order { reminder, _ in reminder.title }
          .select { TaggedTitle.Columns(title: $0.title, tag: $1.name) },
        sectionBy: { _, tag in tag.name },
        database: database
      )
      var rows

      #expect($rows.sections.sectionNames == ["errands", "home", "work"])
      #expect($rows.sections[sectionName: "home"]?.map(\.title) == ["Milk"])
    }

    @Test
    func aJoinedStatementCanBeLoadedWithSections() async throws {
      let database = try await taggedRemindersDatabase()

      @FetchAll var rows = [TaggedTitle]()
      try await $rows.load(
        Reminder
          .join(Tag.all) { $0.id.eq($1.id) }
          .order { reminder, _ in reminder.title }
          .select { TaggedTitle.Columns(title: $0.title, tag: $1.name) },
        sectionBy: { reminder in reminder.priority },
        database: database
      )

      #expect($rows.sections.sectionNames == ["high", "low"])
    }

    @Test
    func anotherProcessesWriteReachesTheProperty() async throws {
      let network = InMemoryIPCTransport.Network()
      let path = OrbitDatabasePath(temporaryDatabasePath("fetch-ipc"))
      let identifier = OrbitDatabaseIdentifier(rawValue: "fetch-ipc")

      let reader = OrbitDatabase(
        writer: try SQLitePool(path: path),
        id: identifier,
        transport: InMemoryIPCTransport(network: network)
      )
      let writer = OrbitDatabase(
        writer: try SQLitePool(path: path),
        id: identifier,
        transport: InMemoryIPCTransport(network: network)
      )
      try await writer.write { transaction in
        try transaction.execute(remindersSchema)
      }

      @FetchAll(Reminder.order(by: \.id), database: reader) var reminders
      #expect(reminders.isEmpty)

      try await writer.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Milk") })
      }

      try await waitUntil { reminders.map(\.title) == ["Milk"] }
    }

    @Test
    func valuesStartWithTheRowsAsTheyStandAndYieldEachChange() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders
      #expect(reminders.count == 1)

      var values = $reminders.values.makeAsyncIterator()
      var titles = await values.next()?.map(\.title)
      #expect(titles == ["Milk"])

      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }
      titles = await values.next()?.map(\.title)
      #expect(titles == ["Milk", "Eggs"])
    }

    @Test
    func valuesStartTheObservationWhenNothingHasReadTheProperty() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders

      var values = $reminders.values.makeAsyncIterator()
      let titles = await values.next()?.map(\.title)
      #expect(titles == ["Milk"])
    }

    @Test
    func valuesOfAMemberReaderFollowThatMember() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.all, database: database) var reminders
      #expect(reminders.count == 1)

      var values = $reminders.count.values.makeAsyncIterator()
      var count = await values.next()
      #expect(count == 1)

      try await database.write { transaction in
        _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }
      count = await values.next()
      #expect(count == 2)
    }

    @Test
    func valuesEndWhenTheIteratingTaskIsCancelled() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.all, database: database) var reminders
      let values = $reminders.values

      let task = Task {
        var count = 0
        for await _ in values { count += 1 }
        return count
      }
      task.cancel()
      #expect(await task.value <= 1)
    }
  }

  // MARK: - Support

  private let remindersSchema = """
    CREATE TABLE IF NOT EXISTS reminders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      isCompleted INTEGER NOT NULL DEFAULT 0,
      priority TEXT
    )
    """

  private func remindersDatabase(
    titles: String...
  ) async throws -> OrbitDatabase<SQLiteQueue> {
    let database = try inMemoryDatabase()
    try await database.write { transaction in
      try transaction.execute(remindersSchema)
      try transaction.execute(
        "CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)"
      )
      for title in titles {
        try transaction.execute(Reminder.insert { Reminder.Draft(title: title) })
      }
    }
    return database
  }

  /// A scheduler that holds everything it is given until a test lets it go, and passes
  /// everything after that straight through.
  private final class HeldScheduler: OrbitValueObservationScheduler {
    private struct State {
      var isHeld = true
      var held: [@Sendable () -> Void] = []
    }

    private let state = Lock(State())

    func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool {
      false
    }

    func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) {
      let runsNow = state.withLock { state -> Bool in
        guard state.isHeld else { return true }
        state.held.append(action)
        return false
      }
      if runsNow { action() }
    }

    /// Runs everything held so far, and stops holding.
    func release() {
      let held = state.withLock { state in
        state.isHeld = false
        defer { state.held = [] }
        return state.held
      }
      for action in held {
        action()
      }
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for the fetched value to change.")
  }

  private func taggedRemindersDatabase() async throws -> OrbitDatabase<SQLiteQueue> {
    let database = try await remindersDatabase()
    try await database.write { transaction in
      try transaction.execute(
        Reminder.insert {
          Reminder.Draft(title: "Milk", priority: "low")
          Reminder.Draft(title: "Eggs", priority: "high")
          Reminder.Draft(title: "Bread", priority: "low")
        }
      )
      try transaction.execute(
        Tag.insert {
          Tag.Draft(name: "home")
          Tag.Draft(name: "errands")
          Tag.Draft(name: "work")
        }
      )
    }
    return database
  }

  @Selection
  private struct TaggedTitle: Equatable, Sendable {
    var title: String
    var tag: String
  }

  @Table("reminders")
  private struct Reminder: Equatable, Sendable {
    let id: Int
    var title: String
    var isCompleted = false
    var priority: String?
  }

  @Table("notes")
  private struct Note: Equatable, Sendable {
    let id: Int
    var title: String
  }

  @Table("tags")
  private struct Tag: Equatable, Sendable {
    let id: Int
    var name: String
  }

  private struct RemindersOverview: OrbitFetchKeyRequest {
    struct Value: Equatable, Sendable {
      var count = 0
      var titles: [String] = []
    }

    func fetch(_ transaction: borrowing SQLiteReadTransaction) throws -> Value {
      try Value(
        count: transaction.fetchCount(Reminder.all),
        titles: transaction.fetchAll(Reminder.order(by: \.id).select(\.title))
      )
    }
  }

  private struct TitleSearch: OrbitFetchKeyRequest {
    let term: String

    func fetch(_ transaction: borrowing SQLiteReadTransaction) throws -> [String] {
      try transaction.fetchAll(
        Reminder.where { $0.title.eq(term) }.select(\.title)
      )
    }
  }
#endif
