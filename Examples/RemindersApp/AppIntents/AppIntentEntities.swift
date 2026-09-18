import AppIntents
import RemindersData
import RemindersIntents

extension ReminderEntity: @retroactive AppEntity {
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Reminder"
  )
  public static let defaultQuery = ReminderEntityQuery()

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      subtitle: "\(list.title)",
      image: .init(systemName: systemImageName)
    )
  }
}

public struct ReminderEntityQuery: EntityStringQuery, _SupportsAppDependencies, Sendable {
  @Dependency
  private var databaseDependency: RemindersIntentDatabase

  private var queries: ReminderEntityQueries {
    ReminderEntityQueries(database: databaseDependency.value)
  }

  public init() {}

  init(database: RemindersDatabase) {
    _databaseDependency = .reminders(database)
  }

  public func entities(
    for identifiers: [ReminderEntity.ID]
  ) async throws -> [ReminderEntity] {
    try await queries.entities(for: identifiers)
  }

  public func suggestedEntities() async throws -> [ReminderEntity] {
    try await queries.suggestedEntities()
  }

  public func entities(matching string: String) async throws -> [ReminderEntity] {
    try await queries.entities(matching: string)
  }

  static func entity(
    id: Reminder.ID,
    database: RemindersDatabase
  ) async throws -> ReminderEntity? {
    try await ReminderEntityQueries.entity(id: id, database: database)
  }
}

extension RemindersListEntity: @retroactive AppEntity {
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Reminders List"
  )
  public static let defaultQuery = RemindersListEntityQuery()

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      image: .init(systemName: "list.bullet")
    )
  }
}

public struct RemindersListEntityQuery: EntityStringQuery, _SupportsAppDependencies, Sendable {
  @Dependency
  private var databaseDependency: RemindersIntentDatabase

  private var queries: RemindersListEntityQueries {
    RemindersListEntityQueries(database: databaseDependency.value)
  }

  public init() {}

  init(database: RemindersDatabase) {
    _databaseDependency = .reminders(database)
  }

  public func entities(
    for identifiers: [RemindersListEntity.ID]
  ) async throws -> [RemindersListEntity] {
    try await queries.entities(for: identifiers)
  }

  public func suggestedEntities() async throws -> [RemindersListEntity] {
    try await queries.suggestedEntities()
  }

  public func entities(matching string: String) async throws -> [RemindersListEntity] {
    try await queries.entities(matching: string)
  }
}

public enum ReminderPriorityParameter: Int, AppEnum, Sendable {
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

  var value: ReminderPriority {
    ReminderPriority(rawValue: rawValue)!
  }
}
