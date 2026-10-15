#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public struct ForeignKeyViolation: Sendable, FetchableRecord, CustomStringConvertible {
    public var originTable: String
    public var originRowID: Int64?
    public var destinationTable: String
    public var foreignKeyId: Int

    public init(row: Row) {
      originTable = row[0]
      originRowID = row[1]
      destinationTable = row[2]
      foreignKeyId = row[3]
    }

    public var description: String {
      "FOREIGN KEY constraint violation - from \(originTable) to \(destinationTable)"
        + (originRowID.map { ", in rowid \($0)" } ?? "")
    }

    public func failureDescription(_ db: Database) throws -> String {
      let key = try db.foreignKeys(on: originTable).first { $0.id == foreignKeyId }
      var message = "FOREIGN KEY constraint violation - from " + originTable
      if let key {
        message += "(" + key.originColumns.joined(separator: ", ") + ")"
      }
      message += " to " + destinationTable
      if let key {
        message += "(" + key.destinationColumns.joined(separator: ", ") + ")"
      }
      if let rowID = originRowID {
        if let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM \(quoted(originTable)) WHERE rowid = ?",
          arguments: [rowID]
        ) {
          message += ", in " + row.description
        } else {
          message += ", in rowid \(rowID)"
        }
      }
      return message
    }

    public func databaseError(_ db: Database) -> DatabaseError {
      DatabaseError(
        resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY,
        message: (try? failureDescription(db)) ?? description
      )
    }
  }

  extension Database {
    public func foreignKeyViolations() throws -> RecordCursor<ForeignKeyViolation> {
      try ForeignKeyViolation.fetchCursor(self, sql: "PRAGMA foreign_key_check")
    }

    public func foreignKeyViolations(in table: String, in schemaName: String? = nil) throws
      -> RecordCursor<ForeignKeyViolation>
    {
      let schema = try requireObjectSchema(table, types: ["table"], in: schemaName)
      return try ForeignKeyViolation.fetchCursor(
        self,
        sql: "PRAGMA \(quoted(schema)).foreign_key_check(\(quoted(table)))"
      )
    }

    public func checkForeignKeys() throws {
      if let violation = try foreignKeyViolations().next() {
        throw violation.databaseError(self)
      }
    }

    public func checkForeignKeys(in table: String, in schemaName: String? = nil) throws {
      if let violation = try foreignKeyViolations(in: table, in: schemaName).next() {
        throw violation.databaseError(self)
      }
    }
  }
#endif
