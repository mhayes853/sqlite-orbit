import AppIntents
import RemindersData

public enum ReminderPriority: Int, AppEnum, Sendable {
  case low = 1
  case medium
  case high

  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Priority"
  )

  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .low: "Low",
    .medium: "Medium",
    .high: "High"
  ]

  public init(_ priority: Reminder.Priority) {
    self = Self(rawValue: priority.rawValue)!
  }

  var reminderPriority: Reminder.Priority {
    Reminder.Priority(rawValue: rawValue)!
  }

  var symbol: String {
    String(repeating: "!", count: rawValue)
  }

  var displayName: String {
    switch self {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    }
  }
}
