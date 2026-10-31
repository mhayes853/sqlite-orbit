#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  public struct UpsertUpdateStrategy: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let noColumnUnlessSpecified = Self([])
    public static let allColumns = Self(rawValue: 1)
  }

  extension MutablePersistableRecord {
    mutating func upsertReturning<T>(
      _ db: Database,
      onConflict target: [String],
      updating strategy: UpsertUpdateStrategy,
      assignments: ((TableAlias<Self>) -> [ColumnAssignment])?,
      selection: [any SQLSelectable],
      decode: (Row) throws -> T
    ) throws -> T {
      try withSaveCallbacks(db) { record in
        let inserted = try record.withInsertCallbacks(db) { container in
          let table = Self.databaseTableName
          let key = try db.primaryKey(table)
          let hasRowID = try db.tableHasRowID(table)
          guard !container.isEmpty else {
            throw DatabaseError(
              resultCode: .SQLITE_MISUSE,
              message: "\(Self.self): invalid empty persistence container"
            )
          }
          let columns = container.fields.map(\.0)
          var sql =
            "INSERT INTO \(quoted(table)) (\(columns.map(quoted).joined(separator: ", "))) VALUES ("
            + Array(repeating: "?", count: columns.count).joined(separator: ",") + ")"
          var arguments = StatementArguments(container.fields.map(\.1))
          sql +=
            target.isEmpty
            ? " ON CONFLICT" : " ON CONFLICT(\(target.map(quoted).joined(separator: ", ")))"
          sql += " DO UPDATE SET "
          let excluded = TableAlias<Self>(name: "excluded")
          var updates = assignments?(excluded) ?? []
          if strategy.contains(.allColumns) {
            let skipped = Set((key.columns + target).map { $0.lowercased() })
            for column in columns {
              let lowercased = column.lowercased()
              if skipped.contains(lowercased)
                || updates.contains(where: { $0.columnName.lowercased() == lowercased })
              {
                continue
              }
              updates.append(Column(column).set(to: excluded[column]))
            }
          }
          let context = SQLGenerationContext(db)
          let updateSQL = try updates.compactMap { try $0.sql(context) }.joined(separator: ", ")
          var returning = selection
          if hasRowID {
            returning.append(Column.rowID)
          }
          if updateSQL.isEmpty {
            if !returning.isEmpty {
              // Update something, so that RETURNING produces a row on conflict.
              let column = quoted(key.columns[0])
              sql += "\(column) = \(column)"
            }
          } else {
            sql += updateSQL
            arguments = arguments &+ context.arguments
          }
          let statement = try returningStatement(
            db,
            sql: SQL(sql: sql, arguments: arguments),
            table: table,
            selection: returning
          )
          let rows = try Row.fetchAll(statement)
          var rowID: Int64 = 0
          let returned: T
          if returning.isEmpty {
            returned = try decode(Row())
          } else {
            guard let row = rows.first else {
              throw DatabaseError(message: "Insertion failed")
            }
            if hasRowID {
              rowID = try row.decode(Int64.self, at: row.count - 1)
            }
            returned = try decode(row)
          }
          var saved = container
          if hasRowID, let column = key.rowIDColumn {
            saved[column] = rowID
          }
          let result = InsertionSuccess(
            rowID: rowID,
            rowIDColumn: hasRowID ? key.rowIDColumn : nil,
            persistenceContainer: saved
          )
          return (result, returned)
        }
        return (
          PersistenceSuccess(persistenceContainer: inserted.0.persistenceContainer), inserted.1
        )
      }
    }

    public mutating func upsert(_ db: Database) throws {
      try upsertReturning(
        db,
        onConflict: [],
        updating: .allColumns,
        assignments: nil,
        selection: []
      ) { _ in () }
    }

    public mutating func upsertAndFetch(
      _ db: Database,
      onConflict target: [String] = [],
      updating strategy: UpsertUpdateStrategy = .allColumns,
      doUpdate assignments: ((TableAlias<Self>) -> [ColumnAssignment])? = nil
    ) throws -> Self where Self: FetchableRecord {
      try upsertReturning(
        db,
        onConflict: target,
        updating: strategy,
        assignments: assignments,
        selection: Self.databaseSelection,
        decode: Self.init(row:)
      )
    }

    public mutating func upsertAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      as returnedType: T.Type,
      onConflict target: [String] = [],
      updating strategy: UpsertUpdateStrategy = .allColumns,
      doUpdate assignments: ((TableAlias<Self>) -> [ColumnAssignment])? = nil
    ) throws -> T {
      try upsertReturning(
        db,
        onConflict: target,
        updating: strategy,
        assignments: assignments,
        selection: T.databaseSelection,
        decode: T.init(row:)
      )
    }
  }

  extension PersistableRecord {
    public func upsert(_ db: Database) throws {
      var copy = self
      try copy.upsertReturning(
        db,
        onConflict: [],
        updating: .allColumns,
        assignments: nil,
        selection: []
      ) { _ in () }
    }

    public func upsertAndFetch(
      _ db: Database,
      onConflict target: [String] = [],
      updating strategy: UpsertUpdateStrategy = .allColumns,
      doUpdate assignments: ((TableAlias<Self>) -> [ColumnAssignment])? = nil
    ) throws -> Self where Self: FetchableRecord {
      var copy = self
      return try copy.upsertReturning(
        db,
        onConflict: target,
        updating: strategy,
        assignments: assignments,
        selection: Self.databaseSelection,
        decode: Self.init(row:)
      )
    }

    public func upsertAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      as returnedType: T.Type,
      onConflict target: [String] = [],
      updating strategy: UpsertUpdateStrategy = .allColumns,
      doUpdate assignments: ((TableAlias<Self>) -> [ColumnAssignment])? = nil
    ) throws -> T {
      var copy = self
      return try copy.upsertReturning(
        db,
        onConflict: target,
        updating: strategy,
        assignments: assignments,
        selection: T.databaseSelection,
        decode: T.init(row:)
      )
    }
  }
#endif
