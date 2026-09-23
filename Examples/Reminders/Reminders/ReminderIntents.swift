import AppIntents
import Foundation
import OSLog
import RemindersData
import RemindersNotifications
import RemindersUI
import SQLiteOrbit
import SwiftUI

enum ReminderIntentPriority: Int, AppEnum, Sendable {
  case low = 1
  case medium
  case high

  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Priority"
  )

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .low: "Low",
    .medium: "Medium",
    .high: "High"
  ]

  init(_ priority: Reminder.Priority) {
    self = Self(rawValue: priority.rawValue)!
  }

  var reminderPriority: Reminder.Priority {
    Reminder.Priority(rawValue: rawValue)!
  }
}

struct CreateReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Create Reminder"
  static let description = IntentDescription(
    "Creates a reminder with optional scheduling and organization details."
  )
  static var parameterSummary: some ParameterSummary {
    Summary("Create reminder ‘\(\.$reminderTitle)’") {
      \.$list
      \.$notes
      \.$dueDate
      \.$isFlagged
      \.$priority
      \.$tags
    }
  }
  static let openAppWhenRun = false

  @Parameter(title: "Title")
  var reminderTitle: String

  @Parameter(title: "List")
  var list: RemindersListEntity?

  @Parameter(title: "Notes")
  var notes: String?

  @Parameter(title: "Due Date")
  var dueDate: Date?

  @Parameter(title: "Flagged", default: false)
  var isFlagged: Bool

  @Parameter(title: "Priority")
  var priority: ReminderIntentPriority?

  @Parameter(title: "Tags")
  var tags: [String]?

  @Dependency(default: OrbitDefaultDatabase.current)
  var database: RemindersDatabase

  @Dependency(default: ReminderNotificationScheduler())
  var notificationScheduler: ReminderNotificationScheduler

  init() {
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
    priority: ReminderIntentPriority? = nil,
    tags: [String]? = nil,
    dependencies: AppDependencyManager
  ) {
    reminderTitle = title
    self.list = list
    self.notes = notes
    self.dueDate = dueDate
    self.isFlagged = isFlagged
    self.priority = priority
    self.tags = tags
    _database = AppDependency(manager: dependencies)
    _notificationScheduler = AppDependency(manager: dependencies)
  }

  func perform() async throws -> some IntentResult
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
            dueDate: dueDate.map { ReminderDate(dateAndTime: $0) },
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
    try await notificationScheduler.reconcile(
      reminderID: reminderID,
      in: database
    )

    guard
      let reminder = try await ReminderEntityQuery.entity(
        id: reminderID,
        database: database
      )
    else { throw ReminderIntentError.reminderNotFound }
    return reminder.intentResult(dialog: "Created the reminder.")
  }
}

struct CompleteReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Reminder"
  static let description = IntentDescription("Marks a reminder as completed.")
  static var parameterSummary: some ParameterSummary {
    Summary("Complete \(\.$reminder)")
  }
  static let supportedModes: IntentModes = [.background]

  // `IntentExecutionTargets` is new in the iOS 27 SDK, which Swift 6.4 ships with.
  #if compiler(>=6.4)
    @available(iOS 27, macOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    static let allowedExecutionTargets: IntentExecutionTargets = [
      .main,
      .widgetKitExtension
    ]
  #endif

  @Parameter(title: "Reminder")
  var reminder: ReminderEntity

  @Dependency(default: OrbitDefaultDatabase.current)
  var database: RemindersDatabase

  @Dependency(default: ReminderNotificationScheduler())
  var notificationScheduler: ReminderNotificationScheduler

  init() {
    reminder = ReminderEntity.placeholder
  }

  init(reminder: ReminderEntity) {
    self.reminder = reminder
  }

  init(
    reminder: ReminderEntity,
    dependencies: AppDependencyManager
  ) {
    self.reminder = reminder
    _database = AppDependency(manager: dependencies)
    _notificationScheduler = AppDependency(manager: dependencies)
  }

  func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    do {
      let updatedReminder = try await reminder.settingStatus(
        .completed,
        in: database,
        scheduler: notificationScheduler
      )
      return updatedReminder.intentResult(dialog: "Completed the reminder.")
    } catch {
      Logger.remindersIntents.error(
        "Could not complete reminder \(reminder.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }
}

struct ReopenReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "Reopen Reminder"
  static let description = IntentDescription("Marks a reminder as incomplete.")
  static var parameterSummary: some ParameterSummary {
    Summary("Reopen \(\.$reminder)")
  }
  static let openAppWhenRun = false

  @Parameter(title: "Reminder")
  var reminder: ReminderEntity

  @Dependency(default: OrbitDefaultDatabase.current)
  var database: RemindersDatabase

  @Dependency(default: ReminderNotificationScheduler())
  var notificationScheduler: ReminderNotificationScheduler

  init() {
    reminder = ReminderEntity.placeholder
  }

  init(reminder: ReminderEntity) {
    self.reminder = reminder
  }

  init(
    reminder: ReminderEntity,
    dependencies: AppDependencyManager
  ) {
    self.reminder = reminder
    _database = AppDependency(manager: dependencies)
    _notificationScheduler = AppDependency(manager: dependencies)
  }

  func perform() async throws -> some IntentResult
    & ReturnsValue<ReminderEntity>
    & ProvidesDialog
    & ShowsSnippetView
  {
    let updatedReminder = try await reminder.settingStatus(
      .incomplete,
      in: database,
      scheduler: notificationScheduler
    )
    return updatedReminder.intentResult(dialog: "Reopened the reminder.")
  }
}

struct DeleteRemindersIntent: DeleteIntent {
  static let title: LocalizedStringResource = "Delete Reminders"
  static let description = IntentDescription("Deletes one or more reminders.")
  static var parameterSummary: some ParameterSummary {
    Summary("Delete \(\.$entities)")
  }
  static let openAppWhenRun = false

  @Parameter(title: "Reminders")
  var entities: [ReminderEntity]

  @Dependency(default: OrbitDefaultDatabase.current)
  var database: RemindersDatabase

  @Dependency(default: ReminderNotificationScheduler())
  var notificationScheduler: ReminderNotificationScheduler

  init() {
    entities = []
  }

  init(
    entities: [ReminderEntity],
    dependencies: AppDependencyManager
  ) {
    self.entities = entities
    _database = AppDependency(manager: dependencies)
    _notificationScheduler = AppDependency(manager: dependencies)
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let ids = entities.map(\.id)
    try await database.write { transaction in
      try Reminder.where { $0.id.in(ids) }.delete().execute(transaction)
    }
    for id in ids {
      try await notificationScheduler.reconcile(reminderID: id, in: database)
    }
    return .result(dialog: "Deleted the reminders.")
  }
}

extension ReminderEntity {
  fileprivate func settingStatus(
    _ status: Reminder.Status,
    in database: RemindersDatabase,
    scheduler: ReminderNotificationScheduler
  ) async throws -> Self {
    try await Reminder.setStatus(
      status,
      id: id,
      in: database,
      scheduler: scheduler
    )
    guard
      let reminder = try await ReminderEntityQuery.entity(
        id: id,
        database: database
      )
    else { throw ReminderIntentError.reminderNotFound }
    return reminder
  }

  fileprivate func intentResult(
    dialog: IntentDialog
  ) -> some IntentResult & ReturnsValue<Self> & ProvidesDialog & ShowsSnippetView {
    .result(
      value: self,
      dialog: dialog,
      view: ReminderSnippetView(
        reminder: reminder,
        remindersList: remindersList,
        tags: tags
      )
    )
  }

  fileprivate static var placeholder: Self {
    let remindersList = RemindersList(id: UUID())
    return Self(
      reminder: Reminder(id: UUID(), remindersListID: remindersList.id),
      remindersList: remindersList
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

extension Logger {
  fileprivate static let remindersIntents = Logger(
    subsystem: "co.sqlite-orbit.Reminders",
    category: "AppIntents"
  )
}
