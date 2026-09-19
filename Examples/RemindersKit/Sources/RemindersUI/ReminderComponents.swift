import RemindersData
import SwiftUI

public struct ReminderCompletionIndicator: View {
  public let color: Color
  public let isCompleted: Bool

  public nonisolated init(isCompleted: Bool, color: Color) {
    self.color = color
    self.isCompleted = isCompleted
  }

  public var body: some View {
    Image(systemName: isCompleted ? "circle.inset.filled" : "circle")
      .foregroundStyle(color)
      .accessibilityHidden(true)
  }
}

public struct ReminderFlagIndicator: View {
  public nonisolated init() {}

  public var body: some View {
    Image(systemName: "flag.fill")
      .foregroundStyle(.orange)
      .accessibilityLabel("Flagged")
  }
}

public struct ReminderPriorityIndicator: View {
  public let color: Color
  public let priority: Reminder.Priority

  public nonisolated init(priority: Reminder.Priority, color: Color) {
    self.color = color
    self.priority = priority
  }

  public var body: some View {
    Text(String(repeating: "!", count: priority.rawValue))
      .foregroundStyle(color)
      .accessibilityLabel("\(displayName) priority")
  }

  private var displayName: String {
    switch priority {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    }
  }
}

public struct ReminderTitle: View {
  public let isCompleted: Bool
  public let reminder: Reminder
  public let title: AttributedString?

  public nonisolated init(
    reminder: Reminder,
    isCompleted: Bool? = nil,
    title: AttributedString? = nil
  ) {
    self.isCompleted = isCompleted ?? reminder.isCompleted
    self.reminder = reminder
    self.title = title
  }

  public var body: some View {
    Text(title ?? AttributedString(reminder.title))
      .foregroundStyle(isCompleted ? .secondary : .primary)
      .strikethrough(isCompleted)
  }
}

public struct ReminderDueDate: View {
  public let dueDate: Date
  public let includesTime: Bool
  public let isPastDue: Bool

  public nonisolated init(
    _ dueDate: Date,
    includesTime: Bool,
    isPastDue: Bool = false
  ) {
    self.dueDate = dueDate
    self.includesTime = includesTime
    self.isPastDue = isPastDue
  }

  public var body: some View {
    Group {
      if includesTime {
        Text(dueDate.formatted(date: .numeric, time: .shortened))
      } else {
        Text(dueDate, style: .date)
      }
    }
    .foregroundStyle(isPastDue ? .red : .secondary)
  }
}

public struct RemindersListIcon: View {
  public let color: Color
  public let size: CGFloat

  public nonisolated init(color: Color, size: CGFloat = 38) {
    self.color = color
    self.size = size
  }

  public var body: some View {
    Image(systemName: "list.bullet")
      .font(.system(size: size * 0.46, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(color.gradient, in: .circle)
      .accessibilityHidden(true)
  }
}
