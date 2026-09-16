import Observation
import SQLiteOrbit
import SwiftUI

enum RemindersDetailType: Hashable, Sendable {
  case all
  case completed
  case flagged
  case list(RemindersList)
  case scheduled
  case tags([Tag])
  case today

  var id: String {
    switch self {
    case .all: "all"
    case .completed: "completed"
    case .flagged: "flagged"
    case .list(let list): "list_\(list.id)"
    case .scheduled: "scheduled"
    case .tags(let tags): "tags_\(tags.map(\.id).sorted().joined(separator: "_"))"
    case .today: "today"
    }
  }

  var navigationTitle: String {
    switch self {
    case .all: "All"
    case .completed: "Completed"
    case .flagged: "Flagged"
    case .list(let list): list.title
    case .scheduled: "Scheduled"
    case .tags(let tags):
      switch tags.count {
      case 0: "Tags"
      case 1: "#\(tags[0].title)"
      default: "\(tags.count) Tags"
      }
    case .today: "Today"
    }
  }

  var color: Color {
    switch self {
    case .all, .completed: .gray
    case .flagged: .orange
    case .list(let list): list.color
    case .scheduled: .red
    case .tags, .today: .blue
    }
  }

  var iconName: String {
    switch self {
    case .all: "tray.circle.fill"
    case .completed: "checkmark.circle.fill"
    case .flagged: "flag.circle.fill"
    case .list: "list.bullet.circle.fill"
    case .scheduled, .today: "calendar.circle.fill"
    case .tags: "number.circle.fill"
    }
  }

  var remindersList: RemindersList? {
    guard case .list(let list) = self else { return nil }
    return list
  }
}

@Selection
nonisolated struct ReminderDetailRow: Identifiable, Sendable {
  var id: Reminder.ID { reminder.id }
  let reminder: Reminder
  let remindersList: RemindersList
  let isPastDue: Bool
  let notes: String
  let tags: String
}

@MainActor
@Observable
final class RemindersDetailModel {
  @ObservationIgnored @FetchAll var reminderRows: [ReminderDetailRow]
  @ObservationIgnored @FetchOne var coverImageData: Data? = nil

  let detailType: RemindersDetailType
  var ordering: ReminderOrdering
  var showCompleted: Bool
  var errorMessage: String?

  @ObservationIgnored private let database: RemindersDatabase
  @ObservationIgnored private let now: Date

  init(
    database: RemindersDatabase,
    detailType: RemindersDetailType,
    now: Date = .now
  ) {
    self.database = database
    self.detailType = detailType
    self.now = now

    let defaults = RemindersDetailSettings(
      id: detailType.id,
      ordering: .dueDate,
      showCompleted: detailType == .completed
    )
    let settings =
      (try? database.readBlocking {
        try RemindersDetailSettings.find(detailType.id).fetchOne($0)
      }) ?? nil
    ordering = settings?.ordering ?? defaults.ordering
    showCompleted = settings?.showCompleted ?? defaults.showCompleted

    _reminderRows = FetchAll(
      Self.remindersQuery(
        detailType: detailType,
        ordering: ordering,
        showCompleted: showCompleted,
        now: now
      ),
      database: database,
      animation: .default
    )
    if let listID = detailType.remindersList?.id {
      _coverImageData = FetchOne(
        RemindersListAsset
          .where { $0.remindersListID.eq(listID) }
          .select(\.coverImage),
        database: database,
        animation: .default
      )
    } else {
      _coverImageData = FetchOne(wrappedValue: nil)
    }
  }

  func setOrdering(_ newValue: ReminderOrdering) async {
    ordering = newValue
    await persistSettingsAndReload()
  }

  func load() async {
    do {
      try await $reminderRows.load()
      if detailType.remindersList != nil {
        try await $coverImageData.load()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func toggleShowCompleted() async {
    showCompleted.toggle()
    await persistSettingsAndReload()
  }

  func moveReminders(from source: IndexSet, to destination: Int) async {
    var ids = reminderRows.map(\.id)
    ids.move(fromOffsets: source, toOffset: destination)
    let orderedIDs = ids
    do {
      try await database.write { transaction in
        for (position, id) in orderedIDs.enumerated() {
          try Reminder.find(id).update { $0.position = position }.execute(transaction)
        }
      }
      ordering = .manual
      await persistSettingsAndReload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func persistSettingsAndReload() async {
    let settings = RemindersDetailSettings(
      id: detailType.id,
      ordering: ordering,
      showCompleted: showCompleted
    )
    do {
      try await database.write { transaction in
        try RemindersDetailSettings.upsert {
          RemindersDetailSettings.Draft(settings)
        }
        .execute(transaction)
      }
      try await $reminderRows.load(
        Self.remindersQuery(
          detailType: detailType,
          ordering: ordering,
          showCompleted: showCompleted,
          now: now
        ),
        database: database,
        animation: .default
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private static func remindersQuery(
    detailType: RemindersDetailType,
    ordering: ReminderOrdering,
    showCompleted: Bool,
    now: Date
  ) -> some Statement<ReminderDetailRow> {
    Reminder
      .where {
        if !showCompleted {
          !$0.isCompleted
        }
      }
      .order {
        if showCompleted {
          $0.isCompleted
        }
      }
      .order {
        switch ordering {
        case .dueDate: $0.dueDate.asc(nulls: .last)
        case .manual: $0.position
        case .priority: ($0.priority.desc(), $0.isFlagged.desc())
        case .title: $0.title
        }
      }
      .withTags
      .where { reminder, _, tag in
        switch detailType {
        case .all: true
        case .completed: reminder.isCompleted
        case .flagged: reminder.isFlagged
        case .list(let list): reminder.remindersListID.eq(list.id)
        case .scheduled: reminder.isScheduled
        case .tags(let tags): tag.primaryKey.ifnull("").in(tags.map(\.primaryKey))
        case .today: reminder.isToday(relativeTo: now)
        }
      }
      .join(RemindersList.all) { $0.remindersListID.eq($3.id) }
      .join(ReminderText.all) { $0.rowid.eq($4.rowid) }
      .select {
        ReminderDetailRow.Columns(
          reminder: $0,
          remindersList: $3,
          isPastDue: $0.isPastDue(relativeTo: now),
          notes: $4.notes.substr(0, 200),
          tags: $4.tags
        )
      }
  }
}

struct RemindersDetailView: View {
  @State var model: RemindersDetailModel
  @State private var reminderForm: ReminderFormContext?

  var body: some View {
    List {
      detailHeader

      ForEach(model.reminderRows) { row in
        ReminderRow(
          color: model.detailType.color,
          database: model.databaseForView,
          isPastDue: row.isPastDue,
          notes: row.notes,
          reminder: row.reminder,
          remindersList: row.remindersList,
          tags: row.tags
        )
      }
      .onMove { source, destination in
        Task { await model.moveReminders(from: source, to: destination) }
      }
    }
    .listStyle(.plain)
    .navigationTitle(model.detailType.navigationTitle)
    .task { await model.load() }
    .toolbarTitleDisplayMode(.inline)
    .toolbar {
      if let list = model.detailType.remindersList {
        ToolbarItem(placement: .bottomBar) {
          HStack {
            Button {
              reminderForm = ReminderFormContext(remindersList: list)
            } label: {
              Label("New Reminder", systemImage: "plus.circle.fill")
                .font(.title3.bold())
            }
            .tint(model.detailType.color)
            Spacer()
          }
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Menu("Sort By") {
            ForEach(ReminderOrdering.allCases, id: \.self) { ordering in
              Button {
                Task { await model.setOrdering(ordering) }
              } label: {
                if model.ordering == ordering {
                  Label(ordering.rawValue, systemImage: "checkmark")
                } else {
                  Text(ordering.rawValue)
                }
              }
            }
          }
          Button {
            Task { await model.toggleShowCompleted() }
          } label: {
            Label(
              model.showCompleted ? "Hide Completed" : "Show Completed",
              systemImage: model.showCompleted ? "eye.slash" : "eye"
            )
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .sheet(item: $reminderForm) { context in
      NavigationStack {
        ReminderFormView(database: model.databaseForView, remindersList: context.remindersList)
      }
    }
    .overlay {
      if model.reminderRows.isEmpty {
        ContentUnavailableView("No Reminders", systemImage: "checkmark.circle")
      }
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

  @ViewBuilder
  private var detailHeader: some View {
    if let data = model.coverImageData, let image = UIImage(data: data) {
      ZStack(alignment: .bottomLeading) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(height: 200)
          .clipped()
        Text(model.detailType.navigationTitle)
          .font(.largeTitle.bold())
          .foregroundStyle(model.detailType.color)
          .padding(10)
          .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
          .padding()
      }
      .listRowInsets(EdgeInsets())
    } else {
      Text(model.detailType.navigationTitle)
        .font(.largeTitle.bold())
        .foregroundStyle(model.detailType.color)
        .listRowSeparator(.hidden)
    }
  }
}

extension RemindersDetailModel {
  fileprivate var databaseForView: RemindersDatabase { database }
}
