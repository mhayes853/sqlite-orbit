import AppIntents
import RemindersData
import SQLiteOrbit
import SwiftUI

public struct RemindersListEntity: AppEntity, Sendable {
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Reminders List"
  )
  public static let defaultQuery = RemindersListEntityQuery()

  public let id: RemindersList.ID

  @Property(title: "Title")
  public var title: String

  public let colorHex: Int64

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      image: .init(systemName: "list.bullet")
    )
  }

  public init(id: RemindersList.ID, title: String, colorHex: Int64) {
    self.id = id
    self.colorHex = colorHex
    self.title = title
  }

  public init(_ remindersList: RemindersList) {
    self.init(
      id: remindersList.id,
      title: remindersList.title,
      colorHex: Color.HexRepresentation(queryOutput: remindersList.color).hexValue ?? 0
    )
  }
}

public struct RemindersListEntityQuery: EntityStringQuery, _SupportsAppDependencies, Sendable {
  @Dependency
  private var databaseDependency: RemindersIntentDatabase

  private var database: RemindersDatabase { databaseDependency.value }

  public init() {}

  public init(database: RemindersDatabase) {
    _databaseDependency = .reminders(database)
  }

  public func entities(
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

  public func suggestedEntities() async throws -> [RemindersListEntity] {
    try await database.read { transaction in
      try RemindersList
        .order { ($0.position, $0.title.collate(.nocase), $0.id) }
        .fetchAll(transaction)
        .map(RemindersListEntity.init)
    }
  }

  public func entities(matching string: String) async throws -> [RemindersListEntity] {
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
