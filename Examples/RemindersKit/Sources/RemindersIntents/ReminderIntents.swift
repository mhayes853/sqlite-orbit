import AppIntents
import Foundation
import RemindersData
import SQLiteOrbit
import SwiftUI

public struct CreateReminderIntent: AppIntent {
  public static let title: LocalizedStringResource = "Create Reminder"
  public static let description = IntentDescription(
    "Creates a reminder with optional scheduling and organization details."
  )
  public static let openAppWhenRun = false

  @Parameter(title: "Title")
  public var reminderTitle: String

  @Parameter(title: "List")
  public var list: RemindersListEntity?

  @Parameter(title: "Notes")
  public var notes: String?

  @Parameter(title: "Due Date")
  public var dueDate: Date?

  @Parameter(title: "Flagged", default: false)
  public var isFlagged: Bool

  @Parameter(title: "Priority")
  public var priority: ReminderPriority?

  @Parameter(title: "Tags")
  public var tags: [String]?

  @Dependency(key: RemindersIntentDependencyKey.database)
  private var database: RemindersDatabase
  private var databaseOverride: RemindersDatabase?

  public init() {
    reminderTitle = ""
    list = nil
    notes = nil
    dueDate = nil
    isFlagged = false
    priority = nil
    tags = nil
    databaseOverride = nil
  }

  init(
    title: String,
    list: RemindersListEntity? = nil,
    notes: String? = nil,
    dueDate: Date? = nil,
    isFlagged: Bool = false,
    priority: ReminderPriority? = nil,
    tags: [String]? = nil,
    database: RemindersDatabase
  ) {
    reminderTitle = title
    self.list = list
    self.notes = notes
    self.dueDate = dueDate
    self.isFlagged = isFlagged
    self.priority = priority
    self.tags = tags
    databaseOverride = database
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let title = reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw ReminderIntentError.missingTitle }

    let database = resolvedDatabase
    let reminderID = Reminder.ID()
    try await database.write { transaction in
      let remindersList: RemindersList
      if let list {
        guard let resolvedList = try RemindersList.find(list.id).fetchOne(transaction)
        else { throw ReminderIntentError.listNotFound }
        remindersList = resolvedList
      } else {
        guard
          let firstList = try
            (RemindersList
            .order { ($0.position, $0.title.collate(.nocase), $0.id) }
            .fetchOne(transaction))
        else { throw ReminderIntentError.noLists }
        remindersList = firstList
      }

      let position = try Reminder.count().fetchOne(transaction) ?? 0
      try Reminder.insert {
        Reminder.Draft(
          Reminder(
            id: reminderID,
            dueDate: dueDate,
            isFlagged: isFlagged,
            notes: notes ?? "",
            position: position,
            priority: priority?.reminderPriority,
            remindersListID: remindersList.id,
            title: title
          )
        )
      }
      .execute(transaction)

      for tagTitle in Self.normalizedTags(tags ?? []) {
        try Tag.upsert { Tag.Draft(Tag(title: tagTitle)) }.execute(transaction)
        try ReminderTag.insert {
          ReminderTag.Draft(
            ReminderTag(id: UUID(), reminderID: reminderID, tagID: tagTitle)
          )
        }
        .execute(transaction)
      }
    }

    guard
      let reminder = try await ReminderEntityQuery.entity(
        id: reminderID,
        database: database
      )
    else { throw ReminderIntentError.reminderNotFound }
    return .result(
      value: reminder,
      dialog: "Created the reminder.",
      view: ReminderSnippetView(reminder: reminder)
    )
  }

  private var resolvedDatabase: RemindersDatabase {
    databaseOverride ?? database
  }

  private static func normalizedTags(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return
      values
      .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
      .map {
        $0
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }
}

public struct CompleteReminderIntent: AppIntent {
  public static let title: LocalizedStringResource = "Complete Reminder"
  public static let description = IntentDescription("Marks a reminder as completed.")
  public static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  public var reminder: ReminderEntity

  @Dependency(key: RemindersIntentDependencyKey.database)
  private var database: RemindersDatabase
  private var databaseOverride: RemindersDatabase?

  public init() {
    reminder = ReminderEntity.placeholder
    databaseOverride = nil
  }

  public init(reminder: ReminderEntity) {
    self.reminder = reminder
    databaseOverride = nil
  }

  init(reminder: ReminderEntity, database: RemindersDatabase) {
    self.reminder = reminder
    databaseOverride = database
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let database = resolvedDatabase
    try await database.write { transaction in
      try Reminder.complete(id: reminder.id).execute(transaction)
    }
    guard
      let updatedReminder = try await ReminderEntityQuery.entity(
        id: reminder.id,
        database: database
      )
    else { throw ReminderIntentError.reminderNotFound }
    return .result(
      value: updatedReminder,
      dialog: "Completed the reminder.",
      view: ReminderSnippetView(reminder: updatedReminder)
    )
  }

  private var resolvedDatabase: RemindersDatabase {
    databaseOverride ?? database
  }
}

public struct ReopenReminderIntent: AppIntent {
  public static let title: LocalizedStringResource = "Reopen Reminder"
  public static let description = IntentDescription("Marks a reminder as incomplete.")
  public static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  public var reminder: ReminderEntity

  @Dependency(key: RemindersIntentDependencyKey.database)
  private var database: RemindersDatabase
  private var databaseOverride: RemindersDatabase?

  public init() {
    reminder = ReminderEntity.placeholder
    databaseOverride = nil
  }

  public init(reminder: ReminderEntity) {
    self.reminder = reminder
    databaseOverride = nil
  }

  init(reminder: ReminderEntity, database: RemindersDatabase) {
    self.reminder = reminder
    databaseOverride = database
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let database = resolvedDatabase
    try await database.write { transaction in
      try Reminder.reopen(id: reminder.id).execute(transaction)
    }
    guard
      let updatedReminder = try await ReminderEntityQuery.entity(
        id: reminder.id,
        database: database
      )
    else { throw ReminderIntentError.reminderNotFound }
    return .result(
      value: updatedReminder,
      dialog: "Reopened the reminder.",
      view: ReminderSnippetView(reminder: updatedReminder)
    )
  }

  private var resolvedDatabase: RemindersDatabase {
    databaseOverride ?? database
  }
}

public struct DeleteRemindersIntent: DeleteIntent {
  public static let title: LocalizedStringResource = "Delete Reminders"
  public static let description = IntentDescription("Deletes one or more reminders.")
  public static let openAppWhenRun = false

  @Parameter(title: "Reminders")
  public var entities: [ReminderEntity]

  @Dependency(key: RemindersIntentDependencyKey.database)
  private var database: RemindersDatabase
  private var databaseOverride: RemindersDatabase?

  public init() {
    entities = []
    databaseOverride = nil
  }

  init(entities: [ReminderEntity], database: RemindersDatabase) {
    self.entities = entities
    databaseOverride = database
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    let ids = entities.map(\.id)
    try await resolvedDatabase.write { transaction in
      try Reminder.where { $0.id.in(ids) }.delete().execute(transaction)
    }
    return .result(dialog: "Deleted the reminders.")
  }

  private var resolvedDatabase: RemindersDatabase {
    databaseOverride ?? database
  }
}

private enum ReminderIntentError: LocalizedError {
  case listNotFound
  case missingTitle
  case noLists
  case reminderNotFound

  var errorDescription: String? {
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

extension ReminderEntity {
  fileprivate static var placeholder: Self {
    Self(
      id: UUID(),
      title: "",
      list: RemindersListEntity(id: UUID(), title: "", colorHex: 0)
    )
  }
}
