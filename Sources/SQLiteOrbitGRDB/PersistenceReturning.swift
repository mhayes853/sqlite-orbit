#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  extension MutablePersistableRecord {
    mutating func insertReturning<T>(
      _ db: Database,
      conflict: Database.ConflictResolution?,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      precondition(!selection.isEmpty, "Invalid empty selection")
      try willSave(db)
      var success: (InsertionSuccess, T)?
      try aroundSave(db) {
        guard success == nil else {
          throw callbackMisuse("aroundSave")
        }
        let result = try insertReturningWithCallbacks(
          db,
          conflict: conflict,
          selection: selection,
          fetch: fetch
        )
        success = result
        return PersistenceSuccess(persistenceContainer: result.0.persistenceContainer)
      }
      guard let success else {
        throw callbackMisuse("aroundSave")
      }
      didSave(PersistenceSuccess(persistenceContainer: success.0.persistenceContainer))
      return success.1
    }

    mutating func insertReturningWithCallbacks<T>(
      _ db: Database,
      conflict: Database.ConflictResolution?,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> (InsertionSuccess, T) {
      try willInsert(db)
      let container = try PersistenceContainer(self)
      var success: (InsertionSuccess, T)?
      try aroundInsert(db) {
        guard success == nil else {
          throw callbackMisuse("aroundInsert")
        }
        let sql = insertionSQL(
          table: Self.databaseTableName,
          container: container,
          conflict: conflict ?? Self.persistenceConflictPolicy.conflictResolutionForInsert
        )
        let statement = try returningStatement(db, sql: sql, selection: selection)
        let returned = try fetch(statement)
        try statement.finishPersistenceExecution()
        let rowID = db.lastInsertedRowID
        let column = try db.primaryKey(Self.databaseTableName).rowIDColumn
        var saved = container
        if let column {
          saved[column] = rowID
        }
        let inserted = InsertionSuccess(
          rowID: rowID,
          rowIDColumn: column,
          persistenceContainer: saved
        )
        success = (inserted, returned)
        return inserted
      }
      guard let success else {
        throw callbackMisuse("aroundInsert")
      }
      didInsert(success.0)
      return success
    }

    func updateReturning<T>(
      _ db: Database,
      conflict: Database.ConflictResolution?,
      columns: Set<String>,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      precondition(!selection.isEmpty, "Invalid empty selection")
      try willSave(db)
      var success: (PersistenceSuccess, T)?
      try aroundSave(db) {
        guard success == nil else {
          throw callbackMisuse("aroundSave")
        }
        let result = try updateReturningWithCallbacks(
          db,
          columns: columns,
          conflict: conflict,
          selection: selection,
          fetch: fetch
        )
        success = result
        return result.0
      }
      guard let success else {
        throw callbackMisuse("aroundSave")
      }
      didSave(success.0)
      return success.1
    }

    func updateReturningWithCallbacks<T>(
      _ db: Database,
      columns: Set<String>,
      conflict: Database.ConflictResolution?,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> (PersistenceSuccess, T) {
      try willUpdate(db, columns: columns)
      let container = try PersistenceContainer(self)
      var success: (PersistenceSuccess, T)?
      try aroundUpdate(db, columns: columns) {
        guard success == nil else {
          throw callbackMisuse("aroundUpdate")
        }
        let sql = try updateSQL(
          db,
          table: Self.databaseTableName,
          container: container,
          columns: columns,
          conflict: conflict ?? Self.persistenceConflictPolicy.conflictResolutionForUpdate
        )
        let statement = try returningStatement(db, sql: sql, selection: selection)
        let returned = try fetch(statement)
        try statement.finishPersistenceExecution()
        guard db.changesCount > 0 else {
          throw try missingRecord(db)
        }
        let updated = PersistenceSuccess(persistenceContainer: container)
        success = (updated, returned)
        return updated
      }
      guard let success else {
        throw callbackMisuse("aroundUpdate")
      }
      didUpdate(success.0)
      return success
    }

    mutating func saveReturning<T>(
      _ db: Database,
      conflict: Database.ConflictResolution?,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      precondition(!selection.isEmpty, "Invalid empty selection")
      try willSave(db)
      var success: (PersistenceSuccess, T)?
      try aroundSave(db) {
        guard success == nil else {
          throw callbackMisuse("aroundSave")
        }
        let container = try PersistenceContainer(self)
        let key = try primaryKeyValues(db, table: Self.databaseTableName, container: container)
        if key.values.allSatisfy({ !$0.isNull }) {
          do {
            let result = try updateReturningWithCallbacks(
              db,
              columns: Set(container.fields.map(\.0)),
              conflict: conflict,
              selection: selection,
              fetch: fetch
            )
            success = result
            return result.0
          } catch RecordError.recordNotFound {}
        }
        let inserted = try insertReturningWithCallbacks(
          db,
          conflict: conflict,
          selection: selection,
          fetch: fetch
        )
        let result = PersistenceSuccess(persistenceContainer: inserted.0.persistenceContainer)
        success = (result, inserted.1)
        return result
      }
      guard let success else {
        throw callbackMisuse("aroundSave")
      }
      didSave(success.0)
      return success.1
    }

    func missingRecord(_ db: Database) throws -> RecordError {
      .recordNotFound(
        databaseTableName: Self.databaseTableName,
        key: try primaryKeyValues(
          db,
          table: Self.databaseTableName,
          container: PersistenceContainer(self)
        )
      )
    }
  }

  func insertionSQL(
    table: String,
    container: PersistenceContainer,
    conflict: Database.ConflictResolution
  ) -> SQL {
    let prefix = "INSERT OR \(conflict.rawValue.uppercased()) INTO \(quoted(table))"
    guard !container.isEmpty else {
      return SQL(sql: prefix + " DEFAULT VALUES")
    }
    let columns = container.fields.map { quoted($0.0) }.joined(separator: ", ")
    let values = Array(repeating: "?", count: container.count).joined(separator: ", ")
    return SQL(
      sql: prefix + " (\(columns)) VALUES (\(values))",
      arguments: StatementArguments(container.fields.map(\.1))
    )
  }

  func updateSQL(
    _ db: Database,
    table: String,
    container: PersistenceContainer,
    columns: Set<String>,
    conflict: Database.ConflictResolution
  ) throws -> SQL {
    let key = try primaryKeyValues(db, table: table, container: container)
    guard key.values.allSatisfy({ !$0.isNull }) else {
      throw RecordError.recordNotFound(databaseTableName: table, key: key)
    }
    let fields = container.fields.filter { field in
      columns.contains { $0.caseInsensitiveCompare(field.0) == .orderedSame }
        && !key.keys.contains { $0.caseInsensitiveCompare(field.0) == .orderedSame }
    }
    let assignments =
      fields.isEmpty
      ? [quoted(key.keys.sorted()[0]) + " = " + quoted(key.keys.sorted()[0])]
      : fields.map { quoted($0.0) + " = ?" }
    let orderedKey = key.sorted { $0.key < $1.key }
    let predicate = orderedKey.map { quoted($0.key) + " = ?" }.joined(separator: " AND ")
    return SQL(
      sql:
        "UPDATE OR \(conflict.rawValue.uppercased()) \(quoted(table)) SET \(assignments.joined(separator: ", ")) WHERE \(predicate)",
      arguments: StatementArguments(fields.map(\.1) + orderedKey.map(\.value))
    )
  }

  func returningStatement(_ db: Database, sql: SQL, selection: [any SQLSelectable]) throws
    -> Statement
  {
    let sql =
      selection.isEmpty
      ? sql : sql + SQL(sql: " RETURNING ") + joined(selection.map(\.sqlSelection), separator: ", ")
    let statement = try db.makeStatement(literal: sql)
    statement.persistenceCursors = []
    return statement
  }

  extension MutablePersistableRecord {
    public mutating func insertAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      return try insertReturning(db, conflict: conflict, selection: selection, fetch: fetch)
    }

    public mutating func insertAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      let record = self
      return try insertReturning(db, conflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try record.missingRecord(db)
        }
        return record
      }
    }

    public func insertAndFetch(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil
    ) throws -> Self where Self: FetchableRecord {
      var copy = self
      return try copy.insertReturning(db, conflict: conflict, selection: Self.databaseSelection) {
        guard let record = try Self.fetchOne($0) else {
          throw try missingRecord(db)
        }
        return record
      }
    }

    public mutating func saveAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      return try saveReturning(db, conflict: conflict, selection: selection, fetch: fetch)
    }

    public mutating func saveAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      let record = self
      return try saveReturning(db, conflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try record.missingRecord(db)
        }
        return record
      }
    }

    public func saveAndFetch(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil
    ) throws -> Self where Self: FetchableRecord {
      var copy = self
      return try copy.saveReturning(db, conflict: conflict, selection: Self.databaseSelection) {
        guard let record = try Self.fetchOne($0) else {
          throw try missingRecord(db)
        }
        return record
      }
    }
  }

  extension PersistableRecord {
    public func insertAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      var copy = self
      return try copy.insertReturning(db, conflict: conflict, selection: selection, fetch: fetch)
    }

    public func insertAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      let record = self
      var copy = self
      return try copy.insertReturning(db, conflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try record.missingRecord(db)
        }
        return record
      }
    }

    public func saveAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      var copy = self
      return try copy.saveReturning(db, conflict: conflict, selection: selection, fetch: fetch)
    }

    public func saveAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      let record = self
      var copy = self
      return try copy.saveReturning(db, conflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try record.missingRecord(db)
        }
        return record
      }
    }
  }

  extension MutablePersistableRecord {
    public func updateAndFetch(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil
    ) throws -> Self where Self: FetchableRecord {
      try updateAndFetch(db, onConflict: conflict, as: Self.self)
    }

    public func updateAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      try updateAndFetch(db, onConflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try missingRecord(db)
        }
        return record
      }
    }

    public func updateAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      try updateReturning(
        db,
        conflict: conflict,
        columns: Set(try PersistenceContainer(self).fields.map(\.0)),
        selection: selection,
        fetch: fetch
      )
    }

    public func updateAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      columns: some Collection<String>,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      try updateReturning(
        db,
        conflict: conflict,
        columns: Set(columns),
        selection: selection,
        fetch: fetch
      )
    }

    public func updateAndFetch(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      columns: some Collection<String>
    ) throws -> Self where Self: FetchableRecord {
      try updateAndFetch(
        db,
        onConflict: conflict,
        columns: columns,
        selection: Self.databaseSelection
      ) {
        guard let record = try Self.fetchOne($0) else {
          throw try missingRecord(db)
        }
        return record
      }
    }
  }

  extension MutablePersistableRecord {
    public func updateAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      columns: some Collection<String>,
      as returnedType: T.Type
    ) throws -> T {
      try updateAndFetch(db, onConflict: conflict, columns: columns, selection: T.databaseSelection)
      {
        guard let record = try T.fetchOne($0) else {
          throw try missingRecord(db)
        }
        return record
      }
    }

    public func updateAndFetch(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      columns: some Collection<some ColumnExpression>
    ) throws -> Self where Self: FetchableRecord {
      try updateAndFetch(db, onConflict: conflict, columns: columns.map(\.name))
    }

    public func updateAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      columns: some Collection<some ColumnExpression>,
      as returnedType: T.Type
    ) throws -> T {
      try updateAndFetch(db, onConflict: conflict, columns: columns.map(\.name), as: returnedType)
    }

    public func updateAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      columns: some Collection<some ColumnExpression>,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      try updateAndFetch(
        db,
        onConflict: conflict,
        columns: columns.map(\.name),
        selection: selection,
        fetch: fetch
      )
    }
  }
#endif
