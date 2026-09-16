import Observation
import SQLiteOrbit
import SwiftUI

typealias RemindersDatabase = any OrbitDatabaseWriter & OrbitObservableDatabase

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
  private let database: RemindersDatabase

  init(database: RemindersDatabase) {
    self.database = database
    _model = State(initialValue: RemindersListsModel(database: database))
  }

  var body: some View {
    List {
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
              onDelete: { Task { await model.deleteList(summary.remindersList) } }
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
    .listStyle(.insetGrouped)
    .navigationTitle("Reminders")
    .task { await model.load() }
    .navigationDestination(for: RemindersDetailType.self) { detailType in
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
    NavigationLink(value: detailType) {
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
