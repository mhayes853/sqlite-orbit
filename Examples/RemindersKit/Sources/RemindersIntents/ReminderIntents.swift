import AppIntents
import Foundation
import RemindersData

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

  @Dependency
  private var databaseDependency: RemindersIntentDatabase

  private var database: RemindersDatabase { databaseDependency.value }

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
    _databaseDependency = .reminders(database)
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let reminder = try await ReminderIntentOperations.create(
      ReminderIntentDraft(
        title: reminderTitle,
        list: list,
        notes: notes,
        dueDate: dueDate,
        isFlagged: isFlagged,
        priority: priority,
        tags: tags
      ),
      in: database
    )
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
  public static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  public var reminder: ReminderEntity

  @Dependency
  private var databaseDependency: RemindersIntentDatabase

  private var database: RemindersDatabase { databaseDependency.value }

  public init() {
    reminder = ReminderEntity.placeholder
  }

  public init(reminder: ReminderEntity) {
    self.reminder = reminder
  }

  init(reminder: ReminderEntity, database: RemindersDatabase) {
    self.reminder = reminder
    _databaseDependency = .reminders(database)
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let updatedReminder = try await ReminderIntentOperations.setStatus(
      .completed,
      for: reminder,
      in: database
    )
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
  public static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  public var reminder: ReminderEntity

  @Dependency
  private var databaseDependency: RemindersIntentDatabase

  private var database: RemindersDatabase { databaseDependency.value }

  public init() {
    reminder = ReminderEntity.placeholder
  }

  public init(reminder: ReminderEntity) {
    self.reminder = reminder
  }

  init(reminder: ReminderEntity, database: RemindersDatabase) {
    self.reminder = reminder
    _databaseDependency = .reminders(database)
  }

  public func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let updatedReminder = try await ReminderIntentOperations.setStatus(
      .incomplete,
      for: reminder,
      in: database
    )
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
  public static let openAppWhenRun = false

  @Parameter(title: "Reminders")
  public var entities: [ReminderEntity]

  @Dependency
  private var databaseDependency: RemindersIntentDatabase

  private var database: RemindersDatabase { databaseDependency.value }

  public init() {
    entities = []
  }

  init(entities: [ReminderEntity], database: RemindersDatabase) {
    self.entities = entities
    _databaseDependency = .reminders(database)
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try await ReminderIntentOperations.delete(entities, in: database)
    return .result(dialog: "Deleted the reminders.")
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
