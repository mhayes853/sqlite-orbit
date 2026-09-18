import RemindersData

public enum ReminderPriority: Int, CaseIterable, Sendable {
  case low = 1
  case medium
  case high

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
