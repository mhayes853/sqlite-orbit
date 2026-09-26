import RemindersData
import SwiftUI

public struct ReminderSnippetView: View {
  public let reminder: Reminder
  public let remindersList: RemindersList
  public let tags: [Tag]

  public nonisolated init(
    reminder: Reminder,
    remindersList: RemindersList,
    tags: [Tag] = []
  ) {
    self.reminder = reminder
    self.remindersList = remindersList
    self.tags = tags
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ReminderCompletionIndicator(
        isCompleted: reminder.isCompleted,
        color: remindersList.color
      )
      .font(.title2)

      VStack(alignment: .leading, spacing: 6) {
        ReminderTitle(reminder: reminder)
          .font(.headline)

        if !reminder.notes.isEmpty {
          Text(reminder.notes)
            .font(.subheadline)
        }

        HStack(spacing: 8) {
          Label(remindersList.title, systemImage: "list.bullet")
          if let dueDate = reminder.dueDate {
            Label {
              ReminderDueDate(dueDate)
            } icon: {
              Image(systemName: "calendar")
            }
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if !tags.isEmpty {
          Text(tags.map { "#\($0.title)" }.joined(separator: "  "))
            .font(.caption)
            .foregroundStyle(remindersList.color)
        }
      }

      Spacer(minLength: 8)

      VStack(spacing: 8) {
        if reminder.isFlagged {
          ReminderFlagIndicator()
        }
        if let priority = reminder.priority {
          ReminderPriorityIndicator(priority: priority, color: .orange)
            .font(.headline)
        }
      }
    }
    .fontDesign(.rounded)
    .padding()
    .accessibilityElement(children: .combine)
  }
}
