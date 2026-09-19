import AppIntents
import Foundation
import RemindersData
import SQLiteOrbit

public struct ReminderEntity: AppEntity, Sendable {
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Reminder"
  )
  public static let defaultQuery = ReminderEntityQuery()

  public let reminder: Reminder
  public let remindersList: RemindersList
  public let tags: [Tag]

  public var id: Reminder.ID { reminder.id }

  @ComputedProperty(title: "Title")
  public var title: String { reminder.title }

  @ComputedProperty(title: "Notes")
  public var notes: String { reminder.notes }

  @ComputedProperty(title: "List")
  public var list: RemindersListEntity { RemindersListEntity(remindersList) }

  @ComputedProperty(title: "Due Date")
  public var dueDate: Date? { reminder.dueDate }

  @ComputedProperty(title: "Completed")
  public var isCompleted: Bool { reminder.isCompleted }

  @ComputedProperty(title: "Flagged")
  public var isFlagged: Bool { reminder.isFlagged }

  @ComputedProperty(title: "Priority")
  public var priority: ReminderPriority? { reminder.priority.map(ReminderPriority.init) }

  @ComputedProperty(title: "Tags")
  public var tagTitles: [String] { tags.map(\.title) }

  @ComputedProperty(title: "Created")
  public var createdAt: Date { reminder.createdAt }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      subtitle: "\(list.title)",
      image: .init(systemName: systemImageName)
    )
  }

  public init(
    reminder: Reminder,
    remindersList: RemindersList,
    tags: [Tag] = []
  ) {
    self.reminder = reminder
    self.remindersList = remindersList
    self.tags = tags
  }

  public init(_ reminder: WidgetReminder) {
    self.init(
      reminder: reminder.reminder,
      remindersList: reminder.remindersList
    )
  }

  private var systemImageName: String {
    if isCompleted {
      "checkmark.circle.fill"
    } else if isFlagged {
      "flag.fill"
    } else {
      "circle"
    }
  }
}

@Selection
private nonisolated struct ReminderEntityRecord: Sendable {
  let reminder: Reminder
  let remindersList: RemindersList
}

@Selection
private nonisolated struct ReminderEntityTag: Sendable {
  let reminderID: Reminder.ID
  let tag: Tag
}

public struct ReminderEntityQuery: EntityStringQuery, _SupportsAppDependencies, Sendable {
  @Dependency(default: OrbitDefaultDatabase.current)
  private var database: RemindersDatabase

  public init() {}

  public init(database: RemindersDatabase) {
    _database = remindersDatabaseDependency(database)
  }

  public func entities(
    for identifiers: [ReminderEntity.ID]
  ) async throws -> [ReminderEntity] {
    let entities = try await database.read { transaction in
      let records =
        try Reminder
        .where { $0.id.in(identifiers) }
        .join(RemindersList.all) { $0.remindersListID.eq($1.id) }
        .select {
          ReminderEntityRecord.Columns(
            reminder: $0,
            remindersList: $1
          )
        }
        .fetchAll(transaction)
      return try Self.entities(records: records, transaction: transaction)
    }
    let entitiesByID: [Reminder.ID: ReminderEntity] = Dictionary(
      uniqueKeysWithValues: entities.map { ($0.id, $0) }
    )
    return identifiers.compactMap { entitiesByID[$0] }
  }

  public func suggestedEntities() async throws -> [ReminderEntity] {
    try await database.read { transaction in
      let records =
        try Reminder
        .where { !$0.isCompleted }
        .order { ($0.createdAt.desc(), $0.id) }
        .limit(20)
        .join(RemindersList.all) { $0.remindersListID.eq($1.id) }
        .select {
          ReminderEntityRecord.Columns(
            reminder: $0,
            remindersList: $1
          )
        }
        .fetchAll(transaction)
      return try Self.entities(records: records, transaction: transaction)
    }
  }

  public func entities(matching string: String) async throws -> [ReminderEntity] {
    let match = Self.ftsMatch(string)
    guard !match.isEmpty else { return try await suggestedEntities() }
    return try await database.read { transaction in
      let records =
        try ReminderText
        .where { $0.match(match) }
        .order(by: \.rank)
        .join(Reminder.all) { $0.rowid.eq($1.rowid) }
        .join(RemindersList.all) { $1.remindersListID.eq($2.id) }
        .limit(20)
        .select {
          ReminderEntityRecord.Columns(
            reminder: $1,
            remindersList: $2
          )
        }
        .fetchAll(transaction)
      return try Self.entities(records: records, transaction: transaction)
    }
  }

  public static func entity(
    id: Reminder.ID,
    database: RemindersDatabase
  ) async throws -> ReminderEntity? {
    try await ReminderEntityQuery(database: database).entities(for: [id]).first
  }

  private static func entities(
    records: [ReminderEntityRecord],
    transaction: borrowing SQLiteReadTransaction
  ) throws -> [ReminderEntity] {
    let reminderIDs = records.map(\.reminder.id)
    let tags =
      try ReminderTag
      .where { $0.reminderID.in(reminderIDs) }
      .order { ($0.reminderID, $0.tagID.collate(.nocase)) }
      .join(Tag.all) { $0.tagID.eq($1.primaryKey) }
      .select {
        ReminderEntityTag.Columns(
          reminderID: $0.reminderID,
          tag: $1
        )
      }
      .fetchAll(transaction)
    let tagsByReminderID: [Reminder.ID: [ReminderEntityTag]] = Dictionary(
      grouping: tags,
      by: \.reminderID
    )
    return records.map {
      ReminderEntity(
        reminder: $0.reminder,
        remindersList: $0.remindersList,
        tags: tagsByReminderID[$0.reminder.id, default: []].map(\.tag)
      )
    }
  }

  private static func ftsMatch(_ string: String) -> String {
    string
      .split(whereSeparator: \.isWhitespace)
      .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
      .joined(separator: " ")
  }
}
