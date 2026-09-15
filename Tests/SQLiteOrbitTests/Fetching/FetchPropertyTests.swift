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
    func fetchAllTracksTheRegionsItRead() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchAll(Reminder.order(by: \.id), database: database) var reminders
      #expect(reminders.count == 1)

      // Writing to a table the query never read must not produce a value.
      try await database.write { transaction in
        try transaction.execute(Tag.insert { Tag.Draft(name: "home") })
      }
      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }

      try await waitUntil { reminders.map(\.title) == ["Milk", "Eggs"] }
    }

    @Test
    func fetchOneObservesAnAggregate() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      @FetchOne(Reminder.all.count(), database: database) var count = 0
      #expect(count == 1)

      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
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
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }
      try await waitUntil { reminders.count == 2 }

      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Bread") })
      }
      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
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
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
      }
      try await Task.sleep(for: .milliseconds(50))

      #expect(reminders.count == 1)
    }

    @Test(arguments: PendingLoadInterruption.allCases)
    func interruptingAPendingLoadResumesItWithCancellation(
      _ interruption: PendingLoadInterruption
    ) async throws {
      let database = try await remindersDatabase(titles: "Milk")
      let scheduler = HeldScheduler()
      let storage = OrbitFetchStorage<[String]>(value: [])
      let source = OrbitFetchSource(
        request: TitleSearch(term: "Milk"),
        database: database,
        scheduler: scheduler
      )
      let completion = Lock<Result<Void, any Error>?>(nil)

      let load = Task {
        do {
          try await storage.load(source)
          completion.withLock { $0 = .success(()) }
        } catch {
          completion.withLock { $0 = .failure(error) }
        }
      }
      defer { load.cancel() }
      try await waitUntil { storage.isLoading }
      switch interruption {
      case .cancel:
        load.cancel()
      case .detach:
        storage.detach()
      case .adoptMissingDatabase:
        storage.adoptIfNeeded(
          from: OrbitFetchStorage(
            value: [],
            loadError: OrbitMissingDefaultDatabaseError(),
            requestID: OrbitFetchRequestID(
              request: TitleSearch(term: "Milk"),
              database: nil,
              scheduler: nil
            )
          )
        )
      }

      try await waitUntil { completion.withLock { $0 != nil } }
      guard case .failure(let error) = completion.withLock({ $0 }) else {
        Issue.record("The interrupted load succeeded.")
        return
      }
      #expect(error is CancellationError)
      if interruption == .cancel {
        // Cancelling the waiter leaves the observation alive; its eventual result must not
        // resume the cancelled continuation a second time.
        #expect(storage.isLoading)
        scheduler.release()
        try await waitUntil { !storage.isLoading }
        #expect(storage.value == ["Milk"])
      } else {
        #expect(!storage.isLoading)
        scheduler.release()
        #expect(storage.value.isEmpty)
      }
      if interruption == .adoptMissingDatabase {
        #expect(storage.requestID != nil)
        #expect(storage.loadError is OrbitMissingDefaultDatabaseError)
      }
    }

    @Test
    func requestIdentityIncludesTheSchedulersConfiguration() async throws {
      let database = try await remindersDatabase()
      let request = TitleSearch(term: "Milk")
      let firstActor = SchedulerActor()
      let secondActor = SchedulerActor()

      func id(
        _ scheduler: (any OrbitValueObservationScheduler & Hashable)?
      ) -> OrbitFetchRequestID {
        OrbitFetchRequestID(request: request, database: database, scheduler: scheduler)
      }

      #expect(id(nil) != id(.immediate))
      #expect(id(OrbitImmediateValueObservationScheduler()) == id(.immediate))
      #expect(id(.async(priority: .utility)) == id(.async(priority: .utility)))
      #expect(Set([id(.async(priority: .utility)), id(.async(priority: .utility))]).count == 1)
      #expect(id(.async(priority: .utility)) != id(.async(priority: .userInitiated)))
      #expect(id(.async(on: firstActor)) == id(.async(on: firstActor)))
      #expect(id(.async(on: firstActor)) != id(.async(on: secondActor)))
      #expect(id(.async()) != id(.async(on: firstActor)))
      #expect(Set([id(.mainActor), id(.mainActor)]).count == 1)
      let held = HeldScheduler()
      #expect(id(held) == id(held))
      #expect(id(held) != id(HeldScheduler()))

      let original = OrbitFetchStorage(
        value: ["original"],
        source: OrbitFetchSource(
          request: request,
          database: database,
          scheduler: OrbitAsyncValueObservationScheduler.async(priority: .utility)
        )
      )
      let sameConfiguration = OrbitFetchStorage(
        value: ["same configuration"],
        source: OrbitFetchSource(
          request: request,
          database: database,
          scheduler: OrbitAsyncValueObservationScheduler.async(priority: .utility)
        )
      )
      let changedConfiguration = OrbitFetchStorage(
        value: ["changed configuration"],
        source: OrbitFetchSource(
          request: request,
          database: database,
          scheduler: OrbitAsyncValueObservationScheduler.async(priority: .userInitiated)
        )
      )

      original.adoptIfNeeded(from: sameConfiguration)
      #expect(original.untrackedValue == ["original"])
      #expect(original.requestID != changedConfiguration.requestID)
      original.adoptIfNeeded(from: changedConfiguration)
      #expect(original.untrackedValue == ["changed configuration"])
      #expect(original.requestID == changedConfiguration.requestID)
    }

    @Test(arguments: ExplicitRequestChange.allCases)
    func unchangedDeclarationsPreserveExplicitRequestChanges(_ change: ExplicitRequestChange)
      async throws
    {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")
      func declaration(_ term: String) -> OrbitFetchStorage<[String]> {
        .make(value: [], request: TitleSearch(term: term), database: database, scheduler: nil)
      }
      let storage = declaration("Milk")
      let declaredID = storage.requestID
      #expect(storage.value == ["Milk"])

      switch change {
      case .load:
        try await storage.load(
          OrbitFetchSource(request: TitleSearch(term: "Eggs"), database: database, scheduler: nil)
        )
      case .assignment:
        storage.adopt(from: declaration("Eggs"))
      case .detach:
        storage.detach()
      }
      let expected = change == .detach ? ["Milk"] : ["Eggs"]
      #expect(storage.value == expected)

      storage.adoptIfNeeded(from: declaration("Milk"))
      #expect(storage.untrackedValue == expected)
      #expect(storage.requestID == declaredID)
      // A value-only declaration also leaves a dynamically loaded request alone.
      storage.adoptIfNeeded(from: OrbitFetchStorage(value: []))
      #expect(storage.untrackedValue == expected)
      #expect(storage.requestID == declaredID)

      let changedDeclaration = declaration("Bread")
      storage.adoptIfNeeded(from: changedDeclaration)
      #expect(storage.requestID == changedDeclaration.requestID)
      #expect(storage.value.isEmpty)
    }

    @Test
    func missingDatabaseDeclarationsKeepTheirIdentityAndRecover() async throws {
      let previous = OrbitDefaultDatabase.current
      OrbitDefaultDatabase.set(nil)
      defer { OrbitDefaultDatabase.set(previous) }
      func declaration(_ term: String) -> OrbitFetchStorage<[String]> {
        .make(value: [], request: TitleSearch(term: term), database: nil, scheduler: nil)
      }
      let storage = declaration("Milk")
      let missingID = try #require(storage.requestID)
      #expect(storage.loadError is OrbitMissingDefaultDatabaseError)
      #expect(declaration("Milk").requestID == missingID)
      #expect(declaration("Eggs").requestID != missingID)

      let database = try await remindersDatabase(titles: "Milk")
      OrbitDefaultDatabase.set(database)
      storage.adoptIfNeeded(from: declaration("Milk"))
      #expect(storage.requestID != missingID)
      #expect(storage.value == ["Milk"])
      #expect(storage.loadError == nil)

      OrbitDefaultDatabase.set(nil)
      storage.adoptIfNeeded(from: declaration("Milk"))
      #expect(storage.requestID == missingID)
      #expect(storage.loadError is OrbitMissingDefaultDatabaseError)
    }

    @Test
    func aStorageWithoutADatabaseStartsReadingWhenOneIsAttached() async throws {
      let previous = OrbitDefaultDatabase.current
      OrbitDefaultDatabase.set(nil)
      defer { OrbitDefaultDatabase.set(previous) }
      let storage = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: nil, scheduler: nil)
      #expect(storage.loadError is OrbitMissingDefaultDatabaseError)

      let database = try await remindersDatabase(titles: "Milk")
      storage.attachIfNeeded(database: database)

      #expect(storage.value == ["Milk"])
      #expect(storage.loadError == nil)
    }

    @Test
    func aStorageWithoutADatabaseFallsBackToADefaultSetAfterwards() async throws {
      let previous = OrbitDefaultDatabase.current
      OrbitDefaultDatabase.set(nil)
      defer { OrbitDefaultDatabase.set(previous) }
      let storage = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: nil, scheduler: nil)

      let database = try await remindersDatabase(titles: "Milk")
      OrbitDefaultDatabase.set(database)
      storage.attachIfNeeded(database: nil)

      #expect(storage.value == ["Milk"])
      #expect(storage.loadError == nil)
    }

    @Test
    func aStorageOnTheProcessDefaultMovesToAnAttachedDatabase() async throws {
      let processDefault = try await remindersDatabase(titles: "Milk")
      let previous = OrbitDefaultDatabase.current
      OrbitDefaultDatabase.set(processDefault)
      defer { OrbitDefaultDatabase.set(previous) }
      let storage = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: nil, scheduler: nil)
      #expect(storage.value == ["Milk"])

      let attached = try await remindersDatabase(titles: "Milk", "Milk")
      storage.attachIfNeeded(database: attached)
      #expect(storage.value == ["Milk", "Milk"])

      // The database it already reads from asks for nothing, and neither does no database at all.
      storage.attachIfNeeded(database: attached)
      storage.attachIfNeeded(database: nil)
      #expect(storage.value == ["Milk", "Milk"])

      // It observes the database it moved to, and no longer the one it left.
      try await attached.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Milk") })
      }
      try await waitUntil { storage.value == ["Milk", "Milk", "Milk"] }
      try await processDefault.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Milk") })
      }
      #expect(storage.value == ["Milk", "Milk", "Milk"])
    }

    @Test
    func anExplicitDatabaseIsNeverReplacedByAnAttachedOne() async throws {
      let explicit = try await remindersDatabase(titles: "Milk")
      let storage = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: explicit, scheduler: nil)
      #expect(storage.value == ["Milk"])

      let attached = try await remindersDatabase(titles: "Milk", "Milk")
      storage.attachIfNeeded(database: attached)

      #expect(storage.value == ["Milk"])
    }

    @Test
    func aDetachedStorageIgnoresAnAttachedDatabase() async throws {
      let database = try await remindersDatabase(titles: "Milk")
      let storage = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: nil, scheduler: nil)
      storage.detach()

      storage.attachIfNeeded(database: database)

      #expect(storage.untrackedValue.isEmpty)
    }

    @Test
    func identicalPropertiesShareOneSubscriptionAndItsValues() async throws {
      let database = try await countingRemindersDatabase(titles: "Milk")
      let first = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: database, scheduler: nil)
      let second = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: database, scheduler: nil)

      #expect(first.value == ["Milk"])
      #expect(second.value == ["Milk"])
      #expect(database.subscriptionCount == 1)

      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Milk") })
      }
      try await waitUntil { first.value == ["Milk", "Milk"] }
      try await waitUntil { second.value == ["Milk", "Milk"] }
    }

    @Test
    func sharingEndsWithTheLastPropertyReadingThroughIt() async throws {
      let database = try await countingRemindersDatabase(titles: "Milk")
      let first = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: database, scheduler: nil)
      let second = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: database, scheduler: nil)
      let id = try #require(first.requestID)
      #expect(first.value == ["Milk"])
      #expect(second.value == ["Milk"])

      first.detach()
      #expect(OrbitFetchObservationRegistry.shared.holdsObservation(for: id))
      try await database.write { transaction in
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Milk") })
      }
      try await waitUntil { second.value == ["Milk", "Milk"] }
      #expect(first.untrackedValue == ["Milk"])

      second.detach()
      #expect(!OrbitFetchObservationRegistry.shared.holdsObservation(for: id))
    }

    @Test
    func propertiesDescribingDifferentReadsDoNotShare() async throws {
      let database = try await countingRemindersDatabase(titles: "Milk", "Eggs")
      let milk = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Milk"), database: database, scheduler: nil)
      let eggs = OrbitFetchStorage<[String]>
        .make(value: [], request: TitleSearch(term: "Eggs"), database: database, scheduler: nil)

      #expect(milk.value == ["Milk"])
      #expect(eggs.value == ["Eggs"])
      #expect(database.subscriptionCount == 2)
    }

    @Test
    func theDefaultDatabaseIsUsedWhenNoneIsGiven() async throws {
      let database = try await remindersDatabase(titles: "Milk")

      OrbitDefaultDatabase.withValue(database) {
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
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
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
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
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
        try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
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

  enum ExplicitRequestChange: CaseIterable, Sendable {
    case load, assignment, detach
  }

  enum PendingLoadInterruption: CaseIterable, Sendable {
    case cancel
    case detach
    case adoptMissingDatabase
  }

  private actor SchedulerActor {}

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

  private func countingRemindersDatabase(
    titles: String...
  ) async throws -> CountingObservableDatabase {
    let database = CountingObservableDatabase(try SQLiteQueue(path: ":memory:"))
    try await database.write { transaction in
      try transaction.execute(remindersSchema)
      for title in titles {
        try transaction.execute(Reminder.insert { Reminder.Draft(title: title) })
      }
    }
    return database
  }

  /// A database that reports its own commits and counts the observers registered on it.
  ///
  /// Nothing else reveals how many subscriptions a pair of fetch properties took out, which is
  /// the whole question when they are meant to be sharing one.
  private final class CountingObservableDatabase: OrbitObservableDatabase {
    let defaultIdentifier: OrbitDatabaseIdentifier

    private let base: SQLiteQueue
    private let observers = OrbitDatabaseTransactionObservers()
    private let subscriptions = Lock(0)

    /// How many observers have been registered, whether or not they are still registered.
    var subscriptionCount: Int {
      subscriptions.withLock { $0 }
    }

    init(_ base: SQLiteQueue) {
      self.base = base
      self.defaultIdentifier = base.defaultIdentifier
    }

    func read<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) async throws -> Result {
      try await base.read(body)
    }

    func readBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) throws -> Result {
      try base.readBlocking(body)
    }

    func readWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) async throws -> Result {
      try await base.readWithoutTransaction(body)
    }

    func readWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) throws -> Result {
      try base.readWithoutTransactionBlocking(body)
    }

    func write<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) async throws -> Result {
      let (result, region) = try await base.write { transaction in
        try transaction.recordingDatabaseRegion(body)
      }
      announceCommit(region: region)
      return result
    }

    func writeBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result {
      let (result, region) = try base.writeBlocking { transaction in
        try transaction.recordingDatabaseRegion(body)
      }
      announceCommit(region: region)
      return result
    }

    func writeWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) async throws -> Result {
      try await base.writeWithoutTransaction(body)
    }

    func writeWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) throws -> Result {
      try base.writeWithoutTransactionBlocking(body)
    }

    func subscribe(
      transactionObserver: any OrbitDatabaseTransactionObserver
    ) throws -> OrbitSubscription {
      subscriptions.withLock { $0 += 1 }
      return observers.subscribe(transactionObserver)
    }

    private func announceCommit(region: OrbitDatabaseRegion) {
      observers.didChange(in: region)
      observers.didCommit(origin: .local, region: region)
    }
  }

  /// A scheduler that holds everything it is given until a test lets it go, and passes
  /// everything after that straight through.
  private final class HeldScheduler: OrbitValueObservationScheduler, Hashable {
    private struct State {
      var isHeld = true
      var held: [@Sendable () -> Void] = []
    }

    private let state = Lock(State())

    static func == (lhs: HeldScheduler, rhs: HeldScheduler) -> Bool {
      lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(self))
    }

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
