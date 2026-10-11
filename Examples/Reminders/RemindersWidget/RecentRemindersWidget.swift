import AppIntents
import RemindersData
import RemindersUI
import SQLiteOrbit
import SwiftUI
import WidgetKit

struct RecentRemindersEntry: TimelineEntry {
  let date: Date
  let reminders: [WidgetReminder]

  static let placeholder: Self = {
    let personal = RemindersList(id: UUID(), title: "Personal")
    let work = RemindersList(id: UUID(), title: "Work")
    return Self(
      date: .now,
      reminders: [
        WidgetReminder(
          reminder: Reminder(
            id: UUID(),
            remindersListID: personal.id,
            title: "Pick up groceries"
          ),
          remindersList: personal
        ),
        WidgetReminder(
          reminder: Reminder(
            id: UUID(),
            dueDate: ReminderDate(date: .now),
            isFlagged: true,
            priority: .high,
            remindersListID: work.id,
            title: "Review the launch notes"
          ),
          remindersList: work
        )
      ]
    )
  }()
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
    Group {
      if entry.reminders.isEmpty {
        widgetContent {
          ContentUnavailableView {
            Label("All Clear", systemImage: "checkmark.circle")
          } description: {
            Text("No recent reminders")
          }
        }
      } else {
        widgetContent(rowLimit: rowLimit)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .fontDesign(.rounded)
    .containerBackground(.background, for: .widget)
  }

  private var rowLimit: Int {
    switch family {
    case .systemLarge:
      6
    default:
      2
    }
  }

  private func widgetContent<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      content()
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func widgetContent(rowLimit: Int) -> some View {
    widgetContent {
      VStack(spacing: 0) {
        ForEach(Array(entry.reminders.prefix(rowLimit).enumerated()), id: \.element.id) {
          index,
          reminder in
          reminderRow(reminder)
          if index < min(entry.reminders.count, rowLimit) - 1 {
            Divider().padding(.leading, 44)
          }
        }
      }
    }
  }

  private var header: some View {
    HStack {
      Label("Reminders", systemImage: "checklist")
        .foregroundStyle(.blue)
      Spacer()
      Text(entry.reminders.count, format: .number)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .font(.headline)
  }

  private func reminderRow(_ reminder: WidgetReminder) -> some View {
    let value = reminder.reminder
    let remindersList = reminder.remindersList

    return HStack(spacing: 8) {
      Button(intent: CompleteReminderIntent(reminder: ReminderEntity(reminder))) {
        ReminderCompletionIndicator(
          isCompleted: value.isCompleted,
          color: remindersList.color
        )
        .font(.title3)
        .invalidatableContent()
      }
      .frame(width: 36, height: 36)
      .contentShape(.rect)
      .buttonStyle(.plain)
      .zIndex(1)
      .accessibilityLabel("Complete \(value.title)")

      Link(destination: RemindersRoute.reminder(value.id).url) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            if let priority = value.priority {
              ReminderPriorityIndicator(priority: priority, color: .orange)
            }
            ReminderTitle(reminder: value)
              .lineLimit(1)
          }
          .font(.subheadline.weight(.medium))

          HStack(spacing: 4) {
            Text(remindersList.title)
            if let dueDate = value.dueDate {
              Text("•")
              ReminderDueDate(dueDate)
            }
            if value.isFlagged {
              ReminderFlagIndicator()
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .buttonStyle(.plain)
    }
    .padding(.vertical, 2)
  }
}

struct RecentRemindersWidget: Widget {
  private let database: RemindersDatabase = OrbitDefaultDatabase.current

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
