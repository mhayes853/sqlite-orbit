import Foundation
import SQLiteOrbit
import SwiftUI

public enum RemindersWidgetConfiguration {
  public static let kind = "RecentRemindersWidget"
  public static let maximumReminderCount = 8
}

@Selection
public nonisolated struct WidgetReminder: Hashable, Identifiable, Sendable {
  public let id: Reminder.ID
  public let createdAt: Date
  public let dueDate: Date?
  public let isFlagged: Bool
  @Column(as: Color.HexRepresentation.self)
  public let listColor: Color
  public let listID: RemindersList.ID
  public let listTitle: String
  public let priority: Reminder.Priority?
  public let title: String

  public init(
    id: Reminder.ID,
    createdAt: Date,
    dueDate: Date? = nil,
    isFlagged: Bool = false,
    listColor: Color = RemindersList.defaultColor,
    listID: RemindersList.ID = UUID(),
    listTitle: String,
    priority: Reminder.Priority? = nil,
    title: String
  ) {
    self.id = id
    self.createdAt = createdAt
    self.dueDate = dueDate
    self.isFlagged = isFlagged
    self.listColor = listColor
    self.listID = listID
    self.listTitle = listTitle
    self.priority = priority
    self.title = title
  }

  public static func recent(
    limit: Int
  ) -> some PartialSelectStatement<WidgetReminder> {
    Reminder
      .where { !$0.isCompleted }
      .order { ($0.createdAt.desc(), $0.id) }
      .join(RemindersList.all) { $0.remindersListID.eq($1.id) }
      .limit(limit)
      .select {
        WidgetReminder.Columns(
          id: $0.id,
          createdAt: $0.createdAt,
          dueDate: $0.dueDate,
          isFlagged: $0.isFlagged,
          listColor: $1.color,
          listID: $1.id,
          listTitle: $1.title,
          priority: $0.priority,
          title: $0.title
        )
      }
  }
}

public extension Reminder {
  static func complete(id: ID) -> UpdateOf<Reminder> {
    find(id).update { $0.status = Reminder.Status.completed }
  }

  static func reopen(id: ID) -> UpdateOf<Reminder> {
    find(id).update { $0.status = Reminder.Status.incomplete }
  }
}
