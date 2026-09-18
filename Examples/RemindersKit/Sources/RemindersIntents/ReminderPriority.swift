import AppIntents
import RemindersData

public enum ReminderPriority: String, AppEnum, Sendable {
  case low
  case medium
  case high

  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Priority"
  )

  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .low: "Low",
    .medium: "Medium",
    .high: "High",
  ]

  public init(_ priority: Reminder.Priority) {
    switch priority {
    case .low: self = .low
    case .medium: self = .medium
    case .high: self = .high
    }
  }

  var reminderPriority: Reminder.Priority {
    switch self {
    case .low: .low
    case .medium: .medium
    case .high: .high
    }
  }
}
