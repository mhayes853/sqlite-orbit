import RemindersData
import SwiftUI
import WidgetKit

struct RecentRemindersEntry: TimelineEntry {
  let date: Date
  let reminders: [WidgetReminder]

  static let placeholder = Self(
    date: .now,
    reminders: [
      WidgetReminder(
        id: UUID(),
        createdAt: .now,
        listTitle: "Personal",
        title: "Pick up groceries"
      ),
      WidgetReminder(
        id: UUID(),
        createdAt: .now,
        dueDate: .now,
        isFlagged: true,
        listTitle: "Work",
        priority: .high,
        title: "Review the launch notes"
      ),
    ]
  )
}

struct RecentRemindersProvider: TimelineProvider {
  private let database: RemindersDatabase

  init(database: RemindersDatabase) {
    self.database = database
  }

  func placeholder(in context: Context) -> RecentRemindersEntry {
    .placeholder
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping @Sendable (RecentRemindersEntry) -> Void
  ) {
    if context.isPreview {
      completion(.placeholder)
    } else {
      Task { completion(await entry()) }
    }
  }

  func getTimeline(
    in context: Context,
    completion: @escaping @Sendable (Timeline<RecentRemindersEntry>) -> Void
  ) {
    Task {
      let entry = await entry()
      completion(Timeline(entries: [entry], policy: .never))
    }
  }

  func entry() async -> RecentRemindersEntry {
    let reminders =
      (try? await database.read { transaction in
        try transaction.fetchAll(
          WidgetReminder.recent(
            limit: RemindersWidgetConfiguration.maximumReminderCount
          )
        )
      }) ?? []
    return RecentRemindersEntry(date: .now, reminders: reminders)
  }
}

struct RecentRemindersWidgetView: View {
  let entry: RecentRemindersEntry

  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Reminders", systemImage: "checklist")
          .font(.headline)
          .foregroundStyle(.blue)
        Spacer()
        Text(entry.reminders.count, format: .number)
          .font(.headline.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if entry.reminders.isEmpty {
        ContentUnavailableView {
          Label("All Clear", systemImage: "checkmark.circle")
        } description: {
          Text("No recent reminders")
        }
      } else {
        VStack(spacing: 0) {
          ForEach(Array(entry.reminders.prefix(rowLimit).enumerated()), id: \.element.id) {
            index, reminder in
            reminderRow(reminder)
            if index < min(entry.reminders.count, rowLimit) - 1 {
              Divider().padding(.leading, 28)
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
    .fontDesign(.rounded)
    .containerBackground(.background, for: .widget)
  }

  private var rowLimit: Int {
    switch family {
    case .systemSmall: 2
    case .systemMedium: 3
    default: 6
    }
  }

  private func reminderRow(_ reminder: WidgetReminder) -> some View {
    HStack(spacing: 8) {
      Button(intent: CompleteReminderIntent(reminderID: reminder.id)) {
        Image(systemName: "circle")
          .font(.title3)
          .foregroundStyle(reminder.listColor)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Complete \(reminder.title)")

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          if let priority = reminder.priority {
            Text(String(repeating: "!", count: priority.rawValue))
              .foregroundStyle(.orange)
          }
          Text(reminder.title)
            .lineLimit(1)
        }
        .font(.subheadline.weight(.medium))

        HStack(spacing: 4) {
          Text(reminder.listTitle)
          if let dueDate = reminder.dueDate {
            Text("•")
            Text(dueDate, style: .date)
          }
          if reminder.isFlagged {
            Image(systemName: "flag.fill")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
  }
}

struct RecentRemindersWidget: Widget {
  private let database: RemindersDatabase

  init() {
    database = RemindersEnvironment.database
  }

  init(database: RemindersDatabase) {
    self.database = database
  }

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: RemindersWidgetConfiguration.kind,
      provider: RecentRemindersProvider(database: database)
    ) { entry in
      RecentRemindersWidgetView(entry: entry)
    }
    .configurationDisplayName("Recent Reminders")
    .description("See and complete your latest reminders.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
