import Foundation
import RemindersData
import SQLiteOrbit

public struct ReminderIntentDraft: Sendable {
  public var title: String
  public var list: RemindersListEntity?
  public var notes: String?
  public var dueDate: Date?
  public var isFlagged: Bool
  public var priority: ReminderPriority?
  public var tags: [String]?

  public init(
    title: String,
    list: RemindersListEntity? = nil,
    notes: String? = nil,
    dueDate: Date? = nil,
    isFlagged: Bool = false,
    priority: ReminderPriority? = nil,
    tags: [String]? = nil
  ) {
    self.title = title
    self.list = list
    self.notes = notes
    self.dueDate = dueDate
    self.isFlagged = isFlagged
    self.priority = priority
    self.tags = tags
  }
}

public enum ReminderIntentOperations {
  public static func create(
    _ draft: ReminderIntentDraft,
    in database: RemindersDatabase
  ) async throws -> ReminderEntity {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw ReminderIntentOperationError.missingTitle }

    let reminderID = Reminder.ID()
    try await database.write { transaction in
      let remindersList: RemindersList
      if let list = draft.list {
        guard let resolvedList = try RemindersList.find(list.id).fetchOne(transaction)
        else { throw ReminderIntentOperationError.listNotFound }
        remindersList = resolvedList
      } else {
        guard
          let firstList = try
            (RemindersList
            .order { ($0.position, $0.title.collate(.nocase), $0.id) }
            .fetchOne(transaction))
        else { throw ReminderIntentOperationError.noLists }
        remindersList = firstList
      }

      let position = try Reminder.count().fetchOne(transaction) ?? 0
      try Reminder.insert {
        Reminder.Draft(
          Reminder(
            id: reminderID,
            dueDate: draft.dueDate,
            isFlagged: draft.isFlagged,
            notes: draft.notes ?? "",
            position: position,
            priority: draft.priority?.reminderPriority,
            remindersListID: remindersList.id,
            title: title
          )
        )
      }
      .execute(transaction)

      try ReminderTag.replaceTags(
        for: reminderID,
        with: draft.tags ?? [],
        in: transaction
      )
    }

    guard
      let reminder = try await ReminderEntityQuery.entity(
        id: reminderID,
        database: database
      )
    else { throw ReminderIntentOperationError.reminderNotFound }
    return reminder
  }

  public static func setStatus(
    _ status: Reminder.Status,
    for reminder: ReminderEntity,
    in database: RemindersDatabase
  ) async throws -> ReminderEntity {
    try await Reminder.setStatus(status, id: reminder.id, in: database)
    guard
      let reminder = try await ReminderEntityQuery.entity(
        id: reminder.id,
        database: database
      )
    else { throw ReminderIntentOperationError.reminderNotFound }
    return reminder
  }

  public static func delete(
    _ reminders: [ReminderEntity],
    in database: RemindersDatabase
  ) async throws {
    let ids = reminders.map(\.id)
    try await database.write { transaction in
      try Reminder.where { $0.id.in(ids) }.delete().execute(transaction)
    }
  }
}

public enum ReminderIntentOperationError: LocalizedError {
  case listNotFound
  case missingTitle
  case noLists
  case reminderNotFound

  public var errorDescription: String? {
    switch self {
    case .listNotFound:
      "The selected reminders list could not be found."
    case .missingTitle:
      "Give the reminder a title before creating it."
    case .noLists:
      "Create a reminders list before adding a reminder."
    case .reminderNotFound:
      "The reminder could not be found."
    }
  }
}
