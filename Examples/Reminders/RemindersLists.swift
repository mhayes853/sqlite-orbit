import Observation
import SQLiteOrbit
import SwiftUI
import TipKit

typealias RemindersDatabase = any OrbitDatabaseWriter & OrbitObservableDatabase

enum RemindersListsSheet: Identifiable {
  case reminder(RemindersList)
  case remindersList(RemindersList?)

  var id: String {
    switch self {
    case .reminder(let list): "new-reminder-\(list.id)"
    case .remindersList(.some(let list)): "edit-list-\(list.id)"
    case .remindersList(.none): "new-list"
    }
  }
}

@Selection
nonisolated struct RemindersListSummary: Identifiable, Sendable {
  var id: RemindersList.ID { remindersList.id }
  let remindersCount: Int
  let remindersList: RemindersList
}

@Selection
nonisolated struct RemindersStats: Sendable {
  var allCount = 0
  var flaggedCount = 0
  var scheduledCount = 0
  var todayCount = 0
}

@MainActor
@Observable
final class RemindersListsModel {
  @ObservationIgnored @FetchAll var remindersLists: [RemindersListSummary]
  @ObservationIgnored @FetchAll var tags: [Tag]
  @ObservationIgnored @FetchOne var stats = RemindersStats()

  var errorMessage: String?
  var presentedSheet: RemindersListsSheet?
  var selectedDetail: RemindersDetailType?
  let seedDatabaseTip = SeedDatabaseTip()

  @ObservationIgnored private let database: RemindersDatabase

  init(database: RemindersDatabase, now: Date = .now) {
    self.database = database
    _remindersLists = FetchAll(
      RemindersList
        .group(by: \.id)
        .order(by: \.position)
        .leftJoin(Reminder.all) { $0.id.eq($1.remindersListID) && !$1.isCompleted }
        .select {
          RemindersListSummary.Columns(
            remindersCount: $1.id.count(),
            remindersList: $0
          )
        },
      database: database,
      animation: .default
    )
    _tags = FetchAll(
      Tag.order(by: \.title),
      database: database,
      animation: .default
    )
    _stats = FetchOne(
      wrappedValue: RemindersStats(),
      Reminder.select {
        RemindersStats.Columns(
          allCount: $0.count(filter: !$0.isCompleted),
          flaggedCount: $0.count(filter: $0.isFlagged && !$0.isCompleted),
          scheduledCount: $0.count(filter: $0.isScheduled),
          todayCount: $0.count(filter: $0.isToday(relativeTo: now))
        )
      },
      database: database,
      animation: .default
    )
  }

  func load() async {
    do {
      try await $remindersLists.load()
      try await $tags.load()
      try await $stats.load()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deleteList(_ list: RemindersList) async {
    await performDatabaseWrite {
      try RemindersList.delete(list).execute($0)
    }
  }

  func deleteTags(at offsets: IndexSet) async {
    let titles = offsets.map { tags[$0].title }
    await performDatabaseWrite {
      try Tag.where { $0.title.in(titles) }.delete().execute($0)
    }
  }

  func moveLists(from source: IndexSet, to destination: Int) async {
    var ids = remindersLists.map(\.id)
    ids.move(fromOffsets: source, toOffset: destination)
    let orderedIDs = ids
    await performDatabaseWrite { transaction in
      for (position, id) in orderedIDs.enumerated() {
        try RemindersList.find(id).update { $0.position = position }.execute(transaction)
      }
    }
  }

  func addListButtonTapped() {
    presentedSheet = .remindersList(nil)
  }

  func editListButtonTapped(_ list: RemindersList) {
    presentedSheet = .remindersList(list)
  }

  func newReminderButtonTapped() {
    guard let list = remindersLists.first?.remindersList else {
      presentedSheet = .remindersList(nil)
      return
    }
    presentedSheet = .reminder(list)
  }

  func selectDetail(_ detailType: RemindersDetailType) {
    selectedDetail = detailType
  }

  func seedSampleData() async {
    guard remindersLists.isEmpty else { return }
    let personalID = UUID()
    let workID = UUID()
    let groceriesID = UUID()
    let presentationID = UUID()
    let now = Date.now
    await performDatabaseWrite { transaction in
      guard try RemindersList.count().fetchOne(transaction) == 0 else { return }
      try RemindersList.insert {
        [
          RemindersList(id: personalID, color: .blue, position: 0, title: "Personal"),
          RemindersList(id: workID, color: .orange, position: 1, title: "Work"),
        ]
      }
      .execute(transaction)
      try Reminder.insert {
        [
          Reminder(
            id: groceriesID,
            dueDate: now,
            notes: "Milk, coffee, and apples",
            position: 0,
            remindersListID: personalID,
            title: "Pick up groceries"
          ),
          Reminder(
            id: presentationID,
            dueDate: now.addingTimeInterval(86_400),
            isFlagged: true,
            notes: "Add the latest launch numbers",
            position: 1,
            priority: .high,
            remindersListID: workID,
            title: "Finish presentation"
          ),
          Reminder(
            id: UUID(),
            position: 2,
            remindersListID: personalID,
            status: .completed,
            title: "Book dentist appointment"
          ),
        ]
      }
      .execute(transaction)
      try Tag.insert { [Tag(title: "errands"), Tag(title: "focus")] }.execute(transaction)
      try ReminderTag.insert {
        [
          ReminderTag(id: UUID(), reminderID: groceriesID, tagID: "errands"),
          ReminderTag(id: UUID(), reminderID: presentationID, tagID: "focus"),
        ]
      }
      .execute(transaction)
    }
    seedDatabaseTip.invalidate(reason: .actionPerformed)
  }

  private func performDatabaseWrite(
    _ operation: @escaping @Sendable (borrowing SQLiteWriteTransaction) throws -> Void
  ) async {
    do {
      try await database.write(operation)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct RemindersListsView: View {
  @State private var model: RemindersListsModel
  @State private var searchModel: SearchRemindersModel
  @State private var searchText = ""
  private let database: RemindersDatabase

  init(database: RemindersDatabase) {
    self.database = database
    _model = State(initialValue: RemindersListsModel(database: database))
    _searchModel = State(initialValue: SearchRemindersModel(database: database))
  }

  var body: some View {
    @Bindable var model = model

    List {
      if !searchText.isEmpty {
        SearchRemindersView(database: database, model: searchModel, searchText: searchText)
      } else {
        Section {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
          GridRow {
            statCell(.today, count: model.stats.todayCount)
            statCell(.scheduled, count: model.stats.scheduledCount)
          }
          GridRow {
            statCell(.all, count: model.stats.allCount)
            statCell(.flagged, count: model.stats.flaggedCount)
          }
          GridRow {
            statCell(.completed, count: nil)
          }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .padding(.horizontal, -20)
      }

      Section("My Lists") {
        ForEach(model.remindersLists) { summary in
          NavigationLink(value: RemindersDetailType.list(summary.remindersList)) {
            RemindersListRow(
              remindersCount: summary.remindersCount,
              remindersList: summary.remindersList,
              onDelete: { Task { await model.deleteList(summary.remindersList) } },
              onEdit: { model.editListButtonTapped(summary.remindersList) }
            )
          }
        }
        .onMove { source, destination in
          Task { await model.moveLists(from: source, to: destination) }
        }
      }

        if !model.tags.isEmpty {
          Section("Tags") {
            ForEach(model.tags) { tag in
              NavigationLink(value: RemindersDetailType.tags([tag])) {
                TagRow(tag: tag)
              }
            }
            .onDelete { offsets in
              Task { await model.deleteTags(at: offsets) }
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Reminders")
    .task { await model.load() }
    .searchable(text: $searchText, prompt: "Search reminders and tags")
    .onChange(of: searchText) { _, newValue in
      searchModel.search(newValue)
    }
    .toolbar {
      if model.remindersLists.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          Button("Add Sample Data", systemImage: "leaf") {
            Task { await model.seedSampleData() }
          }
          .popoverTip(model.seedDatabaseTip)
        }
      }
      ToolbarItemGroup(placement: .bottomBar) {
        Button {
          model.newReminderButtonTapped()
        } label: {
          Label("New Reminder", systemImage: "plus.circle.fill")
            .font(.title3.bold())
        }
        Spacer()
        Button("Add List") {
          model.addListButtonTapped()
        }
        .font(.title3)
      }
    }
    .sheet(item: $model.presentedSheet) { sheet in
      NavigationStack {
        switch sheet {
        case .reminder(let list):
          ReminderFormView(database: database, remindersList: list)
        case .remindersList(let list):
          RemindersListForm(database: database, remindersList: list)
        }
      }
    }
    .navigationDestination(for: RemindersDetailType.self) { detailType in
      RemindersDetailView(model: RemindersDetailModel(database: database, detailType: detailType))
    }
    .navigationDestination(item: $model.selectedDetail) { detailType in
      RemindersDetailView(model: RemindersDetailModel(database: database, detailType: detailType))
    }
    .alert(
      "Database Error",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }

  private func statCell(_ detailType: RemindersDetailType, count: Int?) -> some View {
    Button {
      model.selectDetail(detailType)
    } label: {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 8) {
          Image(systemName: detailType.iconName)
            .font(.largeTitle.bold())
            .foregroundStyle(detailType.color)
            .background(Color.white.clipShape(Circle()).padding(4))
          Text(detailType.navigationTitle)
            .font(.headline.bold())
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let count {
          Text(count, format: .number)
            .font(.largeTitle.bold())
            .fontDesign(.rounded)
        }
      }
      .padding(12)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

struct SeedDatabaseTip: Tip {
  var title: Text { Text("Explore with sample data") }
  var message: Text? { Text("Add a few lists, reminders, and tags to see SQLite Orbit in action.") }
  var image: Image? { Image(systemName: "leaf") }
}
