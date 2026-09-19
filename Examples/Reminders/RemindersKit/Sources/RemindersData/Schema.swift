import Foundation
import SQLiteOrbit
import SwiftUI

@Table
public nonisolated struct RemindersList: Hashable, Identifiable, Sendable {
  public let id: UUID
  @Column(as: Color.HexRepresentation.self)
  public var color: Color = Self.defaultColor
  public var position = 0
  public var title = ""

  public init(
    id: UUID,
    color: Color = Self.defaultColor,
    position: Int = 0,
    title: String = ""
  ) {
    self.id = id
    self.color = color
    self.position = position
    self.title = title
  }

  public static var defaultColor: Color {
    Color(red: 0x4a / 255, green: 0x99 / 255, blue: 0xef / 255)
  }
}

extension RemindersList.Draft: Identifiable, Sendable {}

@Table
public nonisolated struct RemindersListAsset: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let remindersListID: RemindersList.ID
  public var coverImage: Data?
  public var id: RemindersList.ID { remindersListID }

  public init(remindersListID: RemindersList.ID, coverImage: Data? = nil) {
    self.remindersListID = remindersListID
    self.coverImage = coverImage
  }
}

@Table
public nonisolated struct Reminder: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var createdAt = Date()
  public var dueDate: Date?
  public var isFlagged = false
  public var notes = ""
  public var position = 0
  public var priority: Priority?
  public var remindersListID: RemindersList.ID
  public var status: Status = .incomplete
  public var title = ""

  public init(
    id: UUID,
    createdAt: Date = .now,
    dueDate: Date? = nil,
    isFlagged: Bool = false,
    notes: String = "",
    position: Int = 0,
    priority: Priority? = nil,
    remindersListID: RemindersList.ID,
    status: Status = .incomplete,
    title: String = ""
  ) {
    self.id = id
    self.createdAt = createdAt
    self.dueDate = dueDate
    self.isFlagged = isFlagged
    self.notes = notes
    self.position = position
    self.priority = priority
    self.remindersListID = remindersListID
    self.status = status
    self.title = title
  }

  public var isCompleted: Bool { status != .incomplete }

  public enum Priority: Int, CaseIterable, QueryBindable, Sendable {
    case low = 1
    case medium
    case high
  }

  public enum Status: Int, QueryBindable, Sendable {
    case incomplete
    case completed
    case completing
  }
}

extension Reminder.Draft: Identifiable, Sendable {}

extension Updates<Reminder> {
  public mutating func toggleCompletion() {
    self.status = Case(self.status)
      .when(#bind(.incomplete), then: #bind(.completed))
      .else(#bind(.incomplete))
  }
}

@Table
public nonisolated struct Tag: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public var title: String
  public var id: String { title }

  public init(title: String) {
    self.title = title
  }
}

extension Tag {
  public static func normalizedTitles(_ values: [String]) -> [String] {
    var seen = Set<String>()
    let charactersToTrim = CharacterSet.whitespacesAndNewlines.union(
      CharacterSet(charactersIn: "#")
    )
    return
      values
      .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
      .map { $0.trimmingCharacters(in: charactersToTrim) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }
}

@Table("remindersTags")
public nonisolated struct ReminderTag: Hashable, Identifiable, Sendable {
  public let id: UUID
  public let reminderID: Reminder.ID
  public let tagID: Tag.ID

  public init(id: UUID, reminderID: Reminder.ID, tagID: Tag.ID) {
    self.id = id
    self.reminderID = reminderID
    self.tagID = tagID
  }
}

extension ReminderTag {
  public static func replaceTags(
    for reminderID: Reminder.ID,
    with titles: [String],
    in transaction: borrowing SQLiteWriteTransaction
  ) throws {
    try ReminderTag.where { $0.reminderID.eq(reminderID) }.delete().execute(transaction)
    for title in Tag.normalizedTitles(titles) {
      try Tag.upsert { Tag.Draft(title: title) }.execute(transaction)
      try ReminderTag.insert {
        ReminderTag.Draft(id: UUID(), reminderID: reminderID, tagID: title)
      }
      .execute(transaction)
    }
  }
}

@Table
public nonisolated struct ReminderText: FTS5, Sendable {
  public let rowid: Int
  public let title: String
  public let notes: String
  public let tags: String
}

public enum ReminderOrdering: String, CaseIterable, QueryBindable, Sendable {
  case dueDate = "Due Date"
  case manual = "Manual"
  case priority = "Priority"
  case title = "Title"
}

@Table("remindersDetailSettings")
public nonisolated struct RemindersDetailSettings: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let id: String
  public var ordering: ReminderOrdering = .dueDate
  public var showCompleted = false

  public init(
    id: String,
    ordering: ReminderOrdering = .dueDate,
    showCompleted: Bool = false
  ) {
    self.id = id
    self.ordering = ordering
    self.showCompleted = showCompleted
  }
}

@Table("searchSettings")
public nonisolated struct SearchSettings: Hashable, Sendable, SingleRowTable {
  @Column(primaryKey: true)
  public let id: Int
  public var showCompleted = false

  public init(id: Int, showCompleted: Bool = false) {
    self.id = id
    self.showCompleted = showCompleted
  }

  public static let defaultValue = SearchSettings(id: 0)
}

extension Reminder {
  public static var withTags: Select<(), Reminder, (ReminderTag?, Tag?)> {
    group(by: \.id)
      .leftJoin(ReminderTag.all) { $0.id.eq($1.reminderID) }
      .leftJoin(Tag.all) { $1.tagID.eq($2.primaryKey) }
  }
}

nonisolated extension Reminder.TableColumns {
  public var isCompleted: some QueryExpression<Bool> {
    status.neq(Reminder.Status.incomplete)
  }

  public func isPastDue(relativeTo date: Date) -> some QueryExpression<Bool> {
    !isCompleted && #sql("coalesce(date(\(dueDate)) < date(\(date)), 0)")
  }

  public func isToday(relativeTo date: Date) -> some QueryExpression<Bool> {
    !isCompleted && #sql("coalesce(date(\(dueDate)) = date(\(date)), 0)")
  }

  public var isScheduled: some QueryExpression<Bool> {
    !isCompleted && dueDate.isNot(nil)
  }
}

public func remindersMigrator(
  erasesDatabaseOnSchemaChange: Bool = false
) -> OrbitDatabaseMigrator {
  var migrator = OrbitDatabaseMigrator()
  migrator.eraseDatabaseOnSchemaChange = erasesDatabaseOnSchemaChange
  migrator.registerMigration("Create reminders schema") { transaction in
    let defaultColor = Color.HexRepresentation(queryOutput: RemindersList.defaultColor).hexValue!
    try transaction.execute(
      """
      CREATE TABLE "remindersLists" (
        "id" TEXT PRIMARY KEY NOT NULL,
        "color" INTEGER NOT NULL DEFAULT \(defaultColor),
        "position" INTEGER NOT NULL DEFAULT 0,
        "title" TEXT NOT NULL DEFAULT ''
      ) STRICT
      """
    )
    try transaction.execute(
      """
      CREATE TABLE "remindersListAssets" (
        "remindersListID" TEXT PRIMARY KEY NOT NULL
          REFERENCES "remindersLists"("id") ON DELETE CASCADE,
        "coverImage" BLOB
      ) STRICT
      """
    )
    try transaction.execute(
      """
      CREATE TABLE "reminders" (
        "id" TEXT PRIMARY KEY NOT NULL,
        "dueDate" TEXT,
        "isFlagged" INTEGER NOT NULL DEFAULT 0,
        "notes" TEXT NOT NULL DEFAULT '',
        "position" INTEGER NOT NULL DEFAULT 0,
        "priority" INTEGER,
        "remindersListID" TEXT NOT NULL
          REFERENCES "remindersLists"("id") ON DELETE CASCADE,
        "status" INTEGER NOT NULL DEFAULT 0,
        "title" TEXT NOT NULL DEFAULT ''
      ) STRICT
      """
    )
    try transaction.execute(
      """
      CREATE TABLE "tags" (
        "title" TEXT COLLATE NOCASE PRIMARY KEY NOT NULL
      ) STRICT
      """
    )
    try transaction.execute(
      """
      CREATE TABLE "remindersTags" (
        "id" TEXT PRIMARY KEY NOT NULL,
        "reminderID" TEXT NOT NULL REFERENCES "reminders"("id") ON DELETE CASCADE,
        "tagID" TEXT NOT NULL REFERENCES "tags"("title") ON DELETE CASCADE ON UPDATE CASCADE,
        UNIQUE("reminderID", "tagID")
      ) STRICT
      """
    )
    try transaction.execute(
      """
      CREATE TABLE "remindersDetailSettings" (
        "id" TEXT PRIMARY KEY NOT NULL,
        "ordering" TEXT NOT NULL DEFAULT 'Due Date',
        "showCompleted" INTEGER NOT NULL DEFAULT 0
      ) STRICT
      """
    )
    try transaction.execute(
      """
      CREATE VIRTUAL TABLE "reminderTexts" USING fts5(
        "title",
        "notes",
        "tags",
        tokenize = 'trigram'
      )
      """
    )
    try transaction.execute(
      """
      CREATE INDEX "idx_reminders_remindersListID"
      ON "reminders"("remindersListID")
      """
    )
    try transaction.execute(
      """
      CREATE INDEX "idx_remindersTags_reminderID"
      ON "remindersTags"("reminderID")
      """
    )
    try transaction.execute(
      """
      CREATE INDEX "idx_remindersTags_tagID"
      ON "remindersTags"("tagID")
      """
    )
    try transaction.execute(
      """
      CREATE TRIGGER "reminders_insert_text"
      AFTER INSERT ON "reminders"
      BEGIN
        INSERT INTO "reminderTexts"("rowid", "title", "notes", "tags")
        VALUES (new."rowid", new."title", replace(new."notes", char(10), ' '), '');
      END
      """
    )
    try transaction.execute(
      """
      CREATE TRIGGER "reminders_update_text"
      AFTER UPDATE OF "title", "notes" ON "reminders"
      BEGIN
        UPDATE "reminderTexts"
        SET "title" = new."title", "notes" = replace(new."notes", char(10), ' ')
        WHERE "rowid" = new."rowid";
      END
      """
    )
    try transaction.execute(
      """
      CREATE TRIGGER "reminders_delete_text"
      AFTER DELETE ON "reminders"
      BEGIN
        DELETE FROM "reminderTexts" WHERE "rowid" = old."rowid";
      END
      """
    )
    try transaction.execute(
      """
      CREATE TRIGGER "remindersTags_insert_text"
      AFTER INSERT ON "remindersTags"
      BEGIN
        UPDATE "reminderTexts"
        SET "tags" = coalesce((
          SELECT group_concat('#' || "tagID", ' ')
          FROM "remindersTags"
          WHERE "reminderID" = new."reminderID"
          ORDER BY "tagID"
        ), '')
        WHERE "rowid" = (SELECT "rowid" FROM "reminders" WHERE "id" = new."reminderID");
      END
      """
    )
    try transaction.execute(
      """
      CREATE TRIGGER "remindersTags_delete_text"
      AFTER DELETE ON "remindersTags"
      BEGIN
        UPDATE "reminderTexts"
        SET "tags" = coalesce((
          SELECT group_concat('#' || "tagID", ' ')
          FROM "remindersTags"
          WHERE "reminderID" = old."reminderID"
          ORDER BY "tagID"
        ), '')
        WHERE "rowid" = (SELECT "rowid" FROM "reminders" WHERE "id" = old."reminderID");
      END
      """
    )
  }
  migrator.registerMigration("Add search settings") { transaction in
    try transaction.execute(
      """
      CREATE TABLE "searchSettings" (
        "id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 0),
        "showCompleted" INTEGER NOT NULL DEFAULT 0
      ) STRICT
      """
    )
  }
  migrator.registerMigration("Add reminder creation date") { transaction in
    try transaction.execute(
      """
      ALTER TABLE "reminders"
      ADD COLUMN "createdAt" TEXT NOT NULL DEFAULT '1970-01-01 00:00:00.000'
      """
    )
    try transaction.execute(
      """
      UPDATE "reminders"
      SET "createdAt" = strftime('%Y-%m-%d %H:%M:%f', 'now')
      """
    )
  }
  return migrator
}
