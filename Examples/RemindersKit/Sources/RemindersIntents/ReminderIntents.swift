import AppIntents
import Foundation
import RemindersData
import SQLiteOrbit

public struct CreateReminderIntent: AppIntent {
  public static let title: LocalizedStringResource = "Create Reminder"
  public static let description = IntentDescription(
    "Creates a reminder with optional scheduling and organization details."
  )
  public static var parameterSummary: some ParameterSummary {
    Summary("Create reminder ‘\(\.$reminderTitle)’") {
      \.$list
      \.$notes
      \.$dueDate
      \.$isFlagged
      \.$priority
      \.$tags
    }
  }
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

  @Dependency(default: OrbitDefaultDatabase.current)
  private var database: RemindersDatabase

  public init() {
    reminderTitle = ""
    list = nil
    notes = nil
    dueDate = nil
    isFlagged = false
    priority = nil
    tags = nil
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
    _database = remindersDatabaseDependency(database)
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let title = reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw ReminderIntentError.missingTitle }

    let dueDate = dueDate
    let isFlagged = isFlagged
    let list = list
    let notes = notes ?? ""
    let priority = priority?.reminderPriority
    let reminderID = Reminder.ID()
    let tags = tags ?? []
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
            notes: notes,
            position: position,
            priority: priority,
            remindersListID: remindersList.id,
            title: title
          )
        )
      }
      .execute(transaction)

      try ReminderTag.replaceTags(
        for: reminderID,
        with: tags,
        in: transaction
      )
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
}

public struct CompleteReminderIntent: AppIntent {
  public static let title: LocalizedStringResource = "Complete Reminder"
  public static let description = IntentDescription("Marks a reminder as completed.")
  public static var parameterSummary: some ParameterSummary {
    Summary("Complete \(\.$reminder)")
  }
  public static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  public var reminder: ReminderEntity

  @Dependency(default: OrbitDefaultDatabase.current)
  private var database: RemindersDatabase

  public init() {
    reminder = ReminderEntity.placeholder
  }

  public init(reminder: ReminderEntity) {
    self.reminder = reminder
  }

  init(reminder: ReminderEntity, database: RemindersDatabase) {
    self.reminder = reminder
    _database = remindersDatabaseDependency(database)
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let updatedReminder = try await reminder.settingStatus(.completed, in: database)
    return .result(
      value: updatedReminder,
      dialog: "Completed the reminder.",
      view: ReminderSnippetView(reminder: updatedReminder)
    )
  }
}

public struct ReopenReminderIntent: AppIntent {
  public static let title: LocalizedStringResource = "Reopen Reminder"
  public static let description = IntentDescription("Marks a reminder as incomplete.")
  public static var parameterSummary: some ParameterSummary {
    Summary("Reopen \(\.$reminder)")
  }
  public static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  public var reminder: ReminderEntity

  @Dependency(default: OrbitDefaultDatabase.current)
  private var database: RemindersDatabase

  public init() {
    reminder = ReminderEntity.placeholder
  }

  public init(reminder: ReminderEntity) {
    self.reminder = reminder
  }

  init(reminder: ReminderEntity, database: RemindersDatabase) {
    self.reminder = reminder
    _database = remindersDatabaseDependency(database)
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let updatedReminder = try await reminder.settingStatus(.incomplete, in: database)
    return .result(
      value: updatedReminder,
      dialog: "Reopened the reminder.",
      view: ReminderSnippetView(reminder: updatedReminder)
    )
  }
}

public struct DeleteRemindersIntent: DeleteIntent {
  public static let title: LocalizedStringResource = "Delete Reminders"
  public static let description = IntentDescription("Deletes one or more reminders.")
  public static var parameterSummary: some ParameterSummary {
    Summary("Delete \(\.$entities)")
  }
  public static let openAppWhenRun = false

  @Parameter(title: "Reminders")
  public var entities: [ReminderEntity]

  @Dependency(default: OrbitDefaultDatabase.current)
  private var database: RemindersDatabase

  public init() {
    entities = []
  }

  init(entities: [ReminderEntity], database: RemindersDatabase) {
    self.entities = entities
    _database = remindersDatabaseDependency(database)
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    let ids = entities.map(\.id)
    try await database.write { transaction in
      try Reminder.where { $0.id.in(ids) }.delete().execute(transaction)
    }
    return .result(dialog: "Deleted the reminders.")
  }
}

extension ReminderEntity {
  fileprivate func settingStatus(
    _ status: Reminder.Status,
    in database: RemindersDatabase
  ) async throws -> Self {
    try await Reminder.setStatus(status, id: id, in: database)
    guard
      let reminder = try await ReminderEntityQuery.entity(
        id: id,
        database: database
      )
    else { throw ReminderIntentError.reminderNotFound }
    return reminder
  }

  fileprivate static var placeholder: Self {
    Self(
      id: UUID(),
      title: "",
      list: RemindersListEntity(id: UUID(), title: "", colorHex: 0)
    )
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

func remindersDatabaseDependency(
  _ database: RemindersDatabase
) -> AppDependency<RemindersDatabase> {
  let dependency = AppDependency<RemindersDatabase>(manager: AppDependencyManager())
  dependency.wrappedValue = database
  return dependency
}
