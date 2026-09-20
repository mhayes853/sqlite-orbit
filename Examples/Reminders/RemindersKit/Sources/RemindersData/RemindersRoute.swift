import Foundation

public enum RemindersRoute: Hashable, Sendable {
  public static let urlScheme = "orbit-reminders"

  case list(RemindersList.ID)
  case reminder(Reminder.ID)

  public init?(url: URL) {
    guard
      url.scheme?.lowercased() == Self.urlScheme,
      let idString = url.pathComponents.dropFirst().first,
      url.pathComponents.count == 2,
      let id = UUID(uuidString: idString)
    else { return nil }

    switch url.host?.lowercased() {
    case "lists":
      self = .list(id)
    case "reminders":
      self = .reminder(id)
    default:
      return nil
    }
  }

  public var url: URL {
    switch self {
    case .list(let id):
      URL(string: "\(Self.urlScheme)://lists/\(id.uuidString)")!
    case .reminder(let id):
      URL(string: "\(Self.urlScheme)://reminders/\(id.uuidString)")!
    }
  }
}
