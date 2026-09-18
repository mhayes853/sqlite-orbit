import AppIntents
import Foundation
import RemindersData
import SQLiteOrbit
import SwiftUI

public struct ReminderEntity: AppEntity, Sendable {
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Reminder"
  )
  public static let defaultQuery = ReminderEntityQuery()

  public let id: Reminder.ID

  @Property(title: "Title")
  public var title: String

  @Property(title: "Notes")
  public var notes: String

  @Property(title: "List")
  public var list: RemindersListEntity

  @Property(title: "Due Date")
  public var dueDate: Date?

  @Property(title: "Completed")
  public var isCompleted: Bool

  @Property(title: "Flagged")
  public var isFlagged: Bool

  @Property(title: "Priority")
  public var priority: ReminderPriority?

  @Property(title: "Tags")
  public var tags: [String]

  @Property(title: "Created")
  public var createdAt: Date

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      subtitle: "\(list.title)",
      image: .init(systemName: systemImageName)
    )
  }

  public init(
    id: Reminder.ID,
    title: String,
    notes: String = "",
    list: RemindersListEntity,
    dueDate: Date? = nil,
    isCompleted: Bool = false,
    isFlagged: Bool = false,
    priority: ReminderPriority? = nil,
    tags: [String] = [],
    createdAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.list = list
    self.dueDate = dueDate
    self.isCompleted = isCompleted
    self.isFlagged = isFlagged
    self.priority = priority
    self.tags = tags
    self.createdAt = createdAt
  }

  public init(_ reminder: WidgetReminder) {
    self.init(
      id: reminder.id,
      title: reminder.title,
      list: RemindersListEntity(
        id: reminder.listID,
        title: reminder.listTitle,
        colorHex: Color.HexRepresentation(queryOutput: reminder.listColor).hexValue ?? 0
      ),
      dueDate: reminder.dueDate,
      isFlagged: reminder.isFlagged,
      priority: reminder.priority.map(ReminderPriority.init),
      createdAt: reminder.createdAt
    )
  }

  fileprivate init(
    _ reminder: Reminder,
    list: RemindersListEntity,
    tags: [String]
  ) {
    self.init(
      id: reminder.id,
      title: reminder.title,
      notes: reminder.notes,
      list: list,
      dueDate: reminder.dueDate,
      isCompleted: reminder.isCompleted,
      isFlagged: reminder.isFlagged,
      priority: reminder.priority.map(ReminderPriority.init),
      tags: tags,
      createdAt: reminder.createdAt
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
  let title: String
}

public struct ReminderEntityQuery: EntityStringQuery, _SupportsAppDependencies, Sendable {
  @Dependency
  private var databaseDependency: RemindersIntentDatabase

  private var database: RemindersDatabase { databaseDependency.value }

  public init() {}

  init(database: RemindersDatabase) {
    _databaseDependency = .reminders(database)
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

  static func entity(
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
          title: $1.title
        )
      }
      .fetchAll(transaction)
    let tagsByReminderID: [Reminder.ID: [ReminderEntityTag]] = Dictionary(
      grouping: tags,
      by: \.reminderID
    )
    return records.map {
      ReminderEntity(
        $0.reminder,
        list: RemindersListEntity($0.remindersList),
        tags: tagsByReminderID[$0.reminder.id, default: []].map(\.title)
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
