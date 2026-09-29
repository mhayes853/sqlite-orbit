import SQLiteOrbit

public enum RemindersWidgetConfiguration {
  public static let kind = "RecentRemindersWidget"
  public static let maximumReminderCount = 8
}

@Selection
public nonisolated struct WidgetReminder: Hashable, Identifiable, Sendable {
  public let reminder: Reminder
  public let remindersList: RemindersList

  public var id: Reminder.ID { reminder.id }

  public init(
    reminder: Reminder,
    remindersList: RemindersList
  ) {
    self.reminder = reminder
    self.remindersList = remindersList
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
          reminder: $0,
          remindersList: $1
        )
      }
  }
}

extension Reminder {
  public static func setStatus(
    _ status: Status,
    id: ID,
    in database: RemindersDatabase
  ) async throws {
    try await database.write {
      try setStatus(status, id: id).execute($0)
    }
  }

  public static func setStatus(_ status: Status, id: ID) -> UpdateOf<Reminder> {
    find(id).update { $0.status = #bind(status) }
  }
}
