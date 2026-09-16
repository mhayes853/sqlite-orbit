import Foundation
import SQLiteOrbit
import SwiftUI

@Table
nonisolated struct RemindersList: Hashable, Identifiable, Sendable {
  let id: UUID
  @Column(as: Color.HexRepresentation.self)
  var color: Color = Self.defaultColor
  var position = 0
  var title = ""

  static var defaultColor: Color {
    Color(red: 0x4a / 255, green: 0x99 / 255, blue: 0xef / 255)
  }
}

extension RemindersList.Draft: Identifiable {}

@Table
nonisolated struct RemindersListAsset: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  let remindersListID: RemindersList.ID
  var coverImage: Data?
  var id: RemindersList.ID { remindersListID }
}

@Table
nonisolated struct Reminder: Hashable, Identifiable, Sendable {
  let id: UUID
  var dueDate: Date?
  var isFlagged = false
  var notes = ""
  var position = 0
  var priority: Priority?
  var remindersListID: RemindersList.ID
  var status: Status = .incomplete
  var title = ""

  var isCompleted: Bool { status != .incomplete }

  enum Priority: Int, CaseIterable, QueryBindable, Sendable {
    case low = 1
    case medium
    case high
  }

  enum Status: Int, QueryBindable, Sendable {
    case incomplete
    case completed
    case completing
  }
}

extension Reminder.Draft: Identifiable {}

extension Updates<Reminder> {
  mutating func toggleCompletion() {
    self.status = Case(self.status)
      .when(#bind(.incomplete), then: #bind(.completed))
      .else(#bind(.incomplete))
  }
}

@Table
nonisolated struct Tag: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  var title: String
  var id: String { title }
}

@Table("remindersTags")
nonisolated struct ReminderTag: Hashable, Identifiable, Sendable {
  let id: UUID
  let reminderID: Reminder.ID
  let tagID: Tag.ID
}

@Table
nonisolated struct ReminderText: FTS5, Sendable {
  let rowid: Int
  let title: String
  let notes: String
  let tags: String
}

enum ReminderOrdering: String, CaseIterable, QueryBindable, Sendable {
  case dueDate = "Due Date"
  case manual = "Manual"
  case priority = "Priority"
  case title = "Title"
}

@Table("remindersDetailSettings")
nonisolated struct RemindersDetailSettings: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  let id: String
  var ordering: ReminderOrdering = .dueDate
  var showCompleted = false
}

@Table("searchSettings")
nonisolated struct SearchSettings: Hashable, Sendable, SingleRowTable {
  @Column(primaryKey: true)
  let id: Int
  var showCompleted = false

  static let defaultValue = SearchSettings(id: 0)
}

extension Reminder {
  static let withTags = group(by: \.id)
    .leftJoin(ReminderTag.all) { $0.id.eq($1.reminderID) }
    .leftJoin(Tag.all) { $1.tagID.eq($2.primaryKey) }
}

nonisolated extension Reminder.TableColumns {
  var isCompleted: some QueryExpression<Bool> {
    status.neq(Reminder.Status.incomplete)
  }

  func isPastDue(relativeTo date: Date) -> some QueryExpression<Bool> {
    !isCompleted && #sql("coalesce(date(\(dueDate)) < date(\(date)), 0)")
  }

  func isToday(relativeTo date: Date) -> some QueryExpression<Bool> {
    !isCompleted && #sql("coalesce(date(\(dueDate)) = date(\(date)), 0)")
  }

  var isScheduled: some QueryExpression<Bool> {
    !isCompleted && dueDate.isNot(nil)
  }
}

func remindersMigrator(erasesDatabaseOnSchemaChange: Bool = false) -> OrbitDatabaseMigrator {
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
  return migrator
}
