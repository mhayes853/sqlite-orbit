import Observation
import RemindersData
import SQLiteOrbit
import SwiftUI
import TipKit

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
final class RemindersListsModel: ErrorReporting {
  @ObservationIgnored
  @FetchAll(
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
    animation: .default
  )
  var remindersLists: [RemindersListSummary]

  @ObservationIgnored @FetchAll(Tag.order(by: \.title), animation: .default)
  var tags: [Tag]
  @ObservationIgnored @FetchOne var stats = RemindersStats()

  var errorMessage: String?
  var reminderForm: ReminderFormModel?
  var remindersListForm: RemindersListFormModel?
  var search: SearchRemindersModel?
  let seedDatabaseTip = SeedDatabaseTip()

  var allRemindersLists: [RemindersList] {
    remindersLists.map(\.remindersList)
  }

  init(now: Date = .now) {
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
      animation: .default
    )
  }

  func load() async {
    await withErrorReporting {
      async let loadLists: Void = $remindersLists.load()
      async let loadTags: Void = $tags.load()
      async let loadStats: Void = $stats.load()
      _ = try await (loadLists, loadTags, loadStats)
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
    remindersListForm = RemindersListFormModel(remindersList: nil)
  }

  func editListButtonTapped(_ list: RemindersList) {
    remindersListForm = RemindersListFormModel(remindersList: list)
  }

  func newReminderButtonTapped() {
    guard let list = remindersLists.first?.remindersList else {
      errorMessage = "Create a list before adding a reminder."
      return
    }
    reminderForm = ReminderFormModel(remindersList: list)
  }

  func searchButtonTapped() {
    search = SearchRemindersModel()
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
          RemindersList(id: workID, color: .orange, position: 1, title: "Work")
        ]
      }
      .execute(transaction)
      try Reminder.insert {
        [
          Reminder(
            id: groceriesID,
            dueDate: ReminderDate(date: now),
            notes: "Milk, coffee, and apples",
            position: 0,
            remindersListID: personalID,
            title: "Pick up groceries"
          ),
          Reminder(
            id: presentationID,
            dueDate: ReminderDate(date: now.addingTimeInterval(86_400)),
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
          )
        ]
      }
      .execute(transaction)
      try Tag.insert { [Tag(title: "errands"), Tag(title: "focus")] }.execute(transaction)
      try ReminderTag.insert {
        [
          ReminderTag(id: UUID(), reminderID: groceriesID, tagID: "errands"),
          ReminderTag(id: UUID(), reminderID: presentationID, tagID: "focus")
        ]
      }
      .execute(transaction)
    }
    seedDatabaseTip.invalidate(reason: .actionPerformed)
  }

  private func performDatabaseWrite(
    _ operation: @escaping @Sendable (borrowing SQLiteWriteTransaction) throws -> Void
  ) async {
    await withErrorReporting {
      try await OrbitDefaultDatabase.current.write(operation)
    }
  }
}

struct RemindersListsView: View {
  let navigation: RemindersNavigationModel
  let quickActions: RemindersHomeQuickActions

  @State private var model = RemindersListsModel()

  var body: some View {
    @Bindable var model = model

    List {
      if let search = model.search, !search.text.isEmpty {
        SearchRemindersView(
          model: search,
          remindersLists: model.allRemindersLists
        )
      } else {
        Section {
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
              RemindersStatCell(
                count: model.stats.todayCount,
                detailType: .today,
                select: navigation.detailButtonTapped
              )
              RemindersStatCell(
                count: model.stats.scheduledCount,
                detailType: .scheduled,
                select: navigation.detailButtonTapped
              )
            }
            GridRow {
              RemindersStatCell(
                count: model.stats.allCount,
                detailType: .all,
                select: navigation.detailButtonTapped
              )
              RemindersStatCell(
                count: model.stats.flaggedCount,
                detailType: .flagged,
                select: navigation.detailButtonTapped
              )
            }
            GridRow {
              RemindersStatCell(
                count: nil,
                detailType: .completed,
                select: navigation.detailButtonTapped
              )
              Color.clear
            }
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }

        RemindersSectionTitle("My Lists")

        Section {
          ForEach(model.remindersLists) { summary in
            Button {
              navigation.detailButtonTapped(.list(summary.remindersList))
            } label: {
              HStack(spacing: 8) {
                RemindersListRow(
                  remindersCount: summary.remindersCount,
                  remindersList: summary.remindersList,
                  onDelete: { Task { await model.deleteList(summary.remindersList) } },
                  onEdit: { model.editListButtonTapped(summary.remindersList) }
                )
                Image(systemName: "chevron.right")
                  .font(.footnote.bold())
                  .foregroundStyle(.tertiary)
                  .accessibilityHidden(true)
              }
            }
            .buttonStyle(.plain)
          }
          .onMove { source, destination in
            Task { await model.moveLists(from: source, to: destination) }
          }
        }

        if !model.tags.isEmpty {
          RemindersSectionTitle("Tags")

          Section {
            ForEach(model.tags) { tag in
              Button {
                navigation.detailButtonTapped(.tags([tag]))
              } label: {
                HStack {
                  TagRow(tag: tag)
                  Spacer()
                  Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                }
              }
              .buttonStyle(.plain)
            }
            .onDelete { offsets in
              Task { await model.deleteTags(at: offsets) }
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .listSectionSpacing(8)
    .scrollContentBackground(.hidden)
    .background(Color(.systemGroupedBackground))
    .navigationTitle("")
    .toolbarTitleDisplayMode(.inline)
    .task { await model.load() }
    .onChange(of: model.remindersLists.map(\.remindersList), initial: true) { _, lists in
      quickActions.update(for: lists)
    }
    .remindersSearchable(
      search: $model.search,
      prompt: "Search reminders and tags"
    )
    .toolbar {
      if model.remindersLists.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add Sample Data", systemImage: "leaf") {
            Task { await model.seedSampleData() }
          }
          .popoverTip(model.seedDatabaseTip)
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Search", systemImage: "magnifyingglass") {
          model.searchButtonTapped()
        }
        .labelStyle(.iconOnly)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          model.addListButtonTapped()
        } label: {
          Image(systemName: "list.bullet.rectangle")
            .overlay(alignment: .bottomTrailing) {
              Image(systemName: "plus.circle.fill")
                .font(.caption2)
                .offset(x: 3, y: 3)
            }
        }
        .accessibilityLabel("Add List")
      }
      ToolbarItem(placement: .topBarTrailing) {
        EditButton()
      }
    }
    .safeAreaInset(edge: .bottom) {
      Color.clear.frame(height: 72)
    }
    .overlay(alignment: .bottomTrailing) {
      FloatingAddButton(tint: .blue, title: "New Reminder") {
        model.newReminderButtonTapped()
      }
      .padding(24)
      .opacity(model.search == nil ? 1 : 0)
      .allowsHitTesting(model.search == nil)
      .accessibilityHidden(model.search != nil)
    }
    .sheet(item: $model.reminderForm) { formModel in
      NavigationStack {
        ReminderFormView(model: formModel)
      }
    }
    .sheet(item: $model.remindersListForm) { formModel in
      NavigationStack {
        RemindersListForm(model: formModel)
      }
    }
    .errorAlert(message: $model.errorMessage)
  }

}

private struct RemindersSectionTitle: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.title2.bold())
      .foregroundStyle(.primary)
      .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 0, trailing: 16))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
  }
}

private struct RemindersStatCell: View {
  let count: Int?
  let detailType: RemindersDetailType
  let select: (RemindersDetailType) -> Void

  var body: some View {
    Button {
      select(detailType)
    } label: {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top) {
          Image(systemName: detailType.iconName)
            .font(.title2.bold())
          Spacer(minLength: 8)
          if let count {
            Text(count, format: .number)
              .font(.title.bold())
          }
        }
        Text(detailType.navigationTitle)
          .font(.title3.bold())
      }
      .foregroundStyle(.white)
      .padding(14)
      .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
      .background(detailType.color.gradient, in: .rect(cornerRadius: 18))
    }
    .accessibilityLabel(detailType.navigationTitle)
    .accessibilityValue(count.map(String.init) ?? "")
  }
}

struct SeedDatabaseTip: Tip {
  var title: Text { Text("Explore with sample data") }
  var message: Text? { Text("Add a few lists, reminders, and tags to see SQLite Orbit in action.") }
  var image: Image? { Image(systemName: "leaf") }
}
