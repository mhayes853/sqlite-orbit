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

  public var reminderPriority: Reminder.Priority {
    Reminder.Priority(rawValue: rawValue)!
  }

  public var symbol: String {
    String(repeating: "!", count: rawValue)
  }

  public var displayName: String {
    switch self {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    }
  }
}
