// The SwiftUI half of the fetch properties: the `DynamicProperty` conformances, the storage a
// view keeps across its own re-creation, and the `animation:` scheduler. None of it can be
// exercised by reading a property in a test, because all of it is about what SwiftUI does with a
// property between renders — so these tests render the views and read what came out.
#if canImport(ViewInspector) && BuiltInSQLite
  import Combine
  import SwiftUI
  import Testing
  import ViewInspector

  @testable import SQLiteOrbit

  // Hosting is process-wide, and a time limit turns a view that never renders into a failure
  // rather than a test that never returns.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct FetchSwiftUITests {
    @Test
    func viewRendersTheRowsItsPropertyFetched() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")
      let sut = RemindersList(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.texts()
          #expect(texts == ["Milk", "Eggs"])
        }
      }
    }

    @Test
    func viewRedrawsWhenACommittedWriteChangesTheRows() async throws {
      let database = try await remindersDatabase(titles: "Milk")
      let sut = RemindersList(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.texts()
          #expect(texts == ["Milk"])
        }
        try await database.write { transaction in
          _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
        }
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.texts()
          #expect(texts == ["Milk", "Eggs"])
        }
      }
    }

    @Test
    func rebuildingTheViewWithADifferentQueryObservesTheNewOne() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")
      let sut = SearchScreen(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.find(FilteredRemindersList.self).texts()
          #expect(texts == ["Milk"])
          try view.find(button: "Eggs").tap()
        }
        // The child view SwiftUI built for this render describes a different read, so the storage
        // that survived the last one adopts it.
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.find(FilteredRemindersList.self).texts()
          #expect(texts == ["Eggs"])
        }
      }
    }

    @Test
    func rebuildingTheViewWithTheSameQueryKeepsObserving() async throws {
      let database = try await remindersDatabase(titles: "Milk")
      let sut = CounterScreen(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.find(RemindersList.self).texts()
          #expect(texts == ["Milk"])
          try view.find(button: "Rebuild").tap()
        }
        try await database.write { transaction in
          _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
        }
        // The rebuilt property describes the same read, so the observation the first render
        // started is the one still delivering.
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.find(RemindersList.self).texts()
          #expect(texts == ["Milk", "Eggs"])
        }
      }
    }

    @Test
    func viewRendersSectionsInOrder() async throws {
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
      let sut = SectionedRemindersList(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.texts()
          #expect(texts == ["high", "Eggs", "low", "Milk", "Bread"])
        }
      }
    }

    @Test
    func fetchOneRendersAndUpdatesItsValue() async throws {
      let database = try await remindersDatabase(titles: "Milk")
      let sut = RemindersFooter(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.texts()
          #expect(texts == ["1 remaining"])
        }
        try await database.write { transaction in
          _ = try transaction.execute(Reminder.insert { Reminder.Draft(title: "Eggs") })
        }
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.texts()
          #expect(texts == ["2 remaining"])
        }
      }
    }

    @Test
    func animatedPropertyDeliversItsRowsToTheView() async throws {
      let database = try await remindersDatabase(titles: "Milk", "Eggs")
      let sut = AnimatedRemindersList(database: database)

      // An animated property has no rows to render synchronously: they can only arrive on the
      // main actor, which is the render this one is a part of.
      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let texts = try view.texts()
          #expect(texts == ["Milk", "Eggs"])
        }
      }
    }
  }

  // MARK: - Views

  /// Every reminder, in insertion order.
  @MainActor
  private struct RemindersList: View {
    @FetchAll var reminders: [Reminder]
    let inspection = Inspection<Self>()

    init(database: any OrbitObservableDatabase) {
      _reminders = FetchAll(Reminder.order(by: \.id), database: database)
    }

    var body: some View {
      VStack {
        ForEach(reminders, id: \.id) { reminder in
          Text(reminder.title)
        }
      }
      .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }
  }

  /// The reminders titled `title`, which is what changes when the screen around it re-creates it.
  @MainActor
  private struct FilteredRemindersList: View {
    @FetchAll var reminders: [Reminder]

    init(database: any OrbitObservableDatabase, title: String) {
      _reminders = FetchAll(Reminder.where { $0.title.eq(title) }, database: database)
    }

    var body: some View {
      VStack {
        ForEach(reminders, id: \.id) { reminder in
          Text(reminder.title)
        }
      }
    }
  }

  /// Rebuilds its list with a different query on every tap.
  @MainActor
  private struct SearchScreen: View {
    let database: any OrbitObservableDatabase
    let inspection = Inspection<Self>()
    @State private var title = "Milk"

    var body: some View {
      VStack {
        Button("Eggs") { title = "Eggs" }
        FilteredRemindersList(database: database, title: title)
      }
      .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }
  }

  /// Rebuilds its list with the same query on every tap.
  @MainActor
  private struct CounterScreen: View {
    let database: any OrbitObservableDatabase
    let inspection = Inspection<Self>()
    @State private var taps = 0

    var body: some View {
      VStack {
        Button("Rebuild") { taps += 1 }
        RemindersList(database: database)
      }
      .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }
  }

  /// Every reminder, grouped by priority, each section named before its rows.
  @MainActor
  private struct SectionedRemindersList: View {
    @FetchAll var reminders: [Reminder]
    let inspection = Inspection<Self>()

    init(database: any OrbitObservableDatabase) {
      _reminders = FetchAll(Reminder.order(by: \.id), sectionBy: \.priority, database: database)
    }

    var body: some View {
      VStack {
        ForEach($reminders.sections) { section in
          Text(section.name ?? "None")
          ForEach(section, id: \.id) { reminder in
            Text(reminder.title)
          }
        }
      }
      .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }
  }

  /// How many reminders there are.
  @MainActor
  private struct RemindersFooter: View {
    @FetchOne var count = 0
    let inspection = Inspection<Self>()

    init(database: any OrbitObservableDatabase) {
      _count = FetchOne(wrappedValue: 0, Reminder.all.count(), database: database)
    }

    var body: some View {
      Text("\(count) remaining")
        .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }
  }

  /// Every reminder, delivered with an animation rather than as the read produces them.
  @MainActor
  private struct AnimatedRemindersList: View {
    @FetchAll var reminders: [Reminder]
    let inspection = Inspection<Self>()

    init(database: any OrbitObservableDatabase) {
      _reminders = FetchAll(Reminder.order(by: \.id), database: database, animation: .default)
    }

    var body: some View {
      VStack {
        ForEach(reminders, id: \.id) { reminder in
          Text(reminder.title)
        }
      }
      .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }
  }

  // MARK: - Support

  /// How long a render is given to happen before a view is inspected.
  ///
  /// A hosted view renders on the run loop rather than the moment it is hosted, and a change
  /// published from a database queue reaches SwiftUI the same way, so every inspection here waits
  /// out a turn of it first.
  private let settle = Duration.milliseconds(100)

  /// The hook ViewInspector needs to reach a view while SwiftUI is rendering it.
  ///
  /// A view holding one publishes itself to the test on `.onReceive(inspection.notice)`, which is
  /// the only place a view built by SwiftUI, with the state SwiftUI gave it, can be read.
  @MainActor
  private final class Inspection<V>: InspectionEmissary {
    let notice = PassthroughSubject<UInt, Never>()
    var callbacks: [UInt: (V) -> Void] = [:]

    func visit(_ view: V, _ line: UInt) {
      if let callback = callbacks.removeValue(forKey: line) {
        callback(view)
      }
    }
  }

  extension InspectableView {
    /// The strings of every `Text` in this view, top to bottom.
    fileprivate func texts() throws -> [String] {
      try findAll(ViewType.Text.self).map { try $0.string() }
    }
  }

  private func remindersDatabase(
    titles: String...
  ) async throws -> OrbitDatabase<SQLiteQueue> {
    let database = try inMemoryDatabase()
    try await database.write { transaction in
      try transaction.execute(
        """
        CREATE TABLE reminders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          isCompleted INTEGER NOT NULL DEFAULT 0,
          priority TEXT
        )
        """
      )
      for title in titles {
        try transaction.execute(Reminder.insert { Reminder.Draft(title: title) })
      }
    }
    return database
  }

  @Table("reminders")
  private struct Reminder: Equatable, Sendable {
    let id: Int
    var title: String
    var isCompleted = false
    var priority: String?
  }
#endif
