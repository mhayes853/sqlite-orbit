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

  /// A named table reference used to qualify expressions, including UPSERT's excluded row.
  public struct TableAlias<RowDecoder>: Sendable {
    let name: String

    public init(name: String) {
      self.name = name
    }

    public subscript(_ column: some ColumnExpression) -> SQLExpression {
      self[column.name]
    }

    public subscript(_ column: String) -> SQLExpression {
      SQLExpression(sql: quoted(name) + "." + quoted(column))
    }
  }

  extension Column {
    public static let rowID = Column("rowid")
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
      try willSave(db)
      var success: (InsertionSuccess, T)?
      try aroundSave(db) {
        guard success == nil else {
          throw callbackMisuse("aroundSave")
        }
        try willInsert(db)
        let container = try PersistenceContainer(self)
        var inserted: (InsertionSuccess, T)?
        try aroundInsert(db) {
          guard inserted == nil else {
            throw callbackMisuse("aroundInsert")
          }
          let key = try db.primaryKey(Self.databaseTableName)
          guard !container.isEmpty else {
            throw DatabaseError(
              resultCode: .SQLITE_MISUSE,
              message: "upsert requires an encoded column"
            )
          }
          let hasRowID: Bool
          if key.rowIDColumn != nil || key.hiddenRowID {
            hasRowID = true
          } else {
            do {
              _ = try db.access.statementInfo(
                "SELECT rowid FROM \(quoted(Self.databaseTableName)) LIMIT 0"
              )
              hasRowID = true
            } catch let error as SQLiteOrbit.SQLiteError
              where error.message?.range(of: "no such column") != nil
            {
              hasRowID = false
            }
          }
          let excluded = TableAlias<Self>(name: "excluded")
          var updates = assignments?(excluded) ?? []
          if strategy.contains(.allColumns) {
            let excludedColumns = Set((key.columns + target).map { $0.lowercased() })
            for (column, _) in container.fields {
              if !excludedColumns.contains(column.lowercased())
                && !updates.contains(where: {
                  $0.column.caseInsensitiveCompare(column) == .orderedSame
                })
              {
                updates.append(Column(column).set(to: excluded[column]))
              }
            }
          }
          if updates.isEmpty {
            // A harmless update still returns the existing row and its id on conflict.
            let column = key.columns[0]
            updates = [Column(column).set(to: Column(column))]
          }
          var sql = insertionSQL(
            table: Self.databaseTableName,
            container: container,
            conflict: .abort
          )
          sql =
            sql
            + SQL(
              sql: " ON CONFLICT"
                + (target.isEmpty ? "" : " (" + target.map(quoted).joined(separator: ", ") + ")")
                + " DO UPDATE SET "
            )
            + joined(
              updates.map { SQL(sql: quoted($0.column) + " = ") + $0.value },
              separator: ", "
            )
          var returning = selection.map(\.sqlSelection)
          if hasRowID {
            returning.append(Column.rowID.sqlSelection)
          }
          if returning.isEmpty {
            returning = [SQL(sql: "1")]
          }
          sql = sql + SQL(sql: " RETURNING ") + joined(returning, separator: ", ")
          let rows = try Row.fetchAll(db, sql)
          guard let row = rows.first else {
            throw DatabaseError(message: "Insertion failed")
          }
          let rowID: Int64 = hasRowID ? try row.decode(Int64.self, at: row.count - 1) : 0
          let returned = try decode(row)
          var saved = container
          if let column = key.rowIDColumn {
            saved[column] = rowID
          }
          let result = InsertionSuccess(
            rowID: rowID,
            rowIDColumn: key.rowIDColumn,
            persistenceContainer: saved
          )
          inserted = (result, returned)
          return result
        }
        guard let inserted else {
          throw callbackMisuse("aroundInsert")
        }
        didInsert(inserted.0)
        success = inserted
        return PersistenceSuccess(persistenceContainer: inserted.0.persistenceContainer)
      }
      guard let success else {
        throw callbackMisuse("aroundSave")
      }
      didSave(PersistenceSuccess(persistenceContainer: success.0.persistenceContainer))
      return success.1
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
