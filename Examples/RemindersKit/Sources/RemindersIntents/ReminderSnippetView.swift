import RemindersData
import SwiftUI

public struct ReminderSnippetView: View {
  public let reminder: ReminderEntity

  public nonisolated init(reminder: ReminderEntity) {
    self.reminder = reminder
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
        .font(.title2)
        .foregroundStyle(listColor)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text(reminder.title)
          .font(.headline)
          .strikethrough(reminder.isCompleted)

        if !reminder.notes.isEmpty {
          Text(reminder.notes)
            .font(.subheadline)
        }

        HStack(spacing: 8) {
          Label(reminder.list.title, systemImage: "list.bullet")
          if let dueDate = reminder.dueDate {
            Label {
              Text(dueDate, style: .date)
            } icon: {
              Image(systemName: "calendar")
            }
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if !reminder.tags.isEmpty {
          Text(reminder.tags.map { "#\($0)" }.joined(separator: "  "))
            .font(.caption)
            .foregroundStyle(listColor)
        }
      }

      Spacer(minLength: 8)

      VStack(spacing: 8) {
        if reminder.isFlagged {
          Image(systemName: "flag.fill")
            .foregroundStyle(.orange)
            .accessibilityLabel("Flagged")
        }
        if let priority = reminder.priority {
          Text(prioritySymbol(priority))
            .font(.headline)
            .foregroundStyle(.orange)
            .accessibilityLabel("\(priority.displayName) priority")
        }
      }
    }
    .fontDesign(.rounded)
    .padding()
    .accessibilityElement(children: .combine)
  }

  private var listColor: Color {
    Color.HexRepresentation(hexValue: reminder.list.colorHex).queryOutput
  }

  private func prioritySymbol(_ priority: ReminderPriority) -> String {
    switch priority {
    case .low: "!"
    case .medium: "!!"
    case .high: "!!!"
    }
  }
}

private extension ReminderPriority {
  var displayName: String {
    switch self {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    }
  }
}
