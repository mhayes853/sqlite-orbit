import AppIntents
import RemindersData
import SQLiteOrbit

struct RemindersListEntity: AppEntity, Sendable {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Reminders List"
  )
  static let defaultQuery = RemindersListEntityQuery()

  let remindersList: RemindersList

  var id: RemindersList.ID { remindersList.id }

  @ComputedProperty(title: "Title")
  var title: String { remindersList.title }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      image: .init(systemName: "list.bullet")
    )
  }

  init(_ remindersList: RemindersList) {
    self.remindersList = remindersList
  }
}

struct RemindersListEntityQuery: EntityStringQuery, _SupportsAppDependencies, Sendable {
  @Dependency(default: OrbitDefaultDatabase.current)
  var database: RemindersDatabase

  init() {}

  init(dependencies: AppDependencyManager) {
    _database = AppDependency(manager: dependencies)
  }

  func entities(
    for identifiers: [RemindersListEntity.ID]
  ) async throws -> [RemindersListEntity] {
    let remindersLists = try await database.read { transaction in
      try RemindersList
        .where { $0.id.in(identifiers) }
        .fetchAll(transaction)
    }
    let remindersListsByID = Dictionary(uniqueKeysWithValues: remindersLists.map { ($0.id, $0) })
    return identifiers.compactMap { remindersListsByID[$0].map(RemindersListEntity.init) }
  }

  func suggestedEntities() async throws -> [RemindersListEntity] {
    try await database.read { transaction in
      try RemindersList
        .order { ($0.position, $0.title.collate(.nocase), $0.id) }
        .fetchAll(transaction)
        .map(RemindersListEntity.init)
    }
  }

  func entities(matching string: String) async throws -> [RemindersListEntity] {
    let pattern = "%\(Self.escapedLikePattern(string))%"
    return try await database.read { transaction in
      try RemindersList
        .where { $0.title.like(pattern, escape: "\\") }
        .order { ($0.position, $0.title.collate(.nocase), $0.id) }
        .fetchAll(transaction)
        .map(RemindersListEntity.init)
    }
  }

  private static func escapedLikePattern(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }
}
