#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  extension MutablePersistableRecord {
    // Empty selections execute without RETURNING; public fetch APIs require a selection.
    mutating func insertRecord<T>(
      _ db: Database,
      conflict: Database.ConflictResolution?,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      try withSaveCallbacks(db) { record in
        let inserted = try record.insertWithCallbacks(
          db,
          conflict: conflict,
          selection: selection,
          fetch: fetch
        )
        return (
          PersistenceSuccess(persistenceContainer: inserted.0.persistenceContainer), inserted.1
        )
      }
    }

    mutating func insertWithCallbacks<T>(
      _ db: Database,
      conflict: Database.ConflictResolution?,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> (InsertionSuccess, T) {
      try withInsertCallbacks(db) { container in
        // Resolve schema information before executing, as GRDB does.
        let column = try db.primaryKey(Self.databaseTableName).rowIDColumn
        let sql = insertionSQL(
          table: Self.databaseTableName,
          container: container,
          conflict: conflict ?? Self.persistenceConflictPolicy.conflictResolutionForInsert
        )
        let statement = try returningStatement(
          db,
          sql: sql,
          table: Self.databaseTableName,
          selection: selection
        )
        let returned = try fetch(statement)
        try statement.finishPersistenceExecution()
        let rowID = db.lastInsertedRowID
        var saved = container
        if let column {
          saved[column] = rowID
        }
        let inserted = InsertionSuccess(
          rowID: rowID,
          rowIDColumn: column,
          persistenceContainer: saved
        )
        return (inserted, returned)
      }
    }

    func updateRecord<T>(
      _ db: Database,
      conflict: Database.ConflictResolution?,
      columns: Set<String>,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      var copy = self
      return try copy.withSaveCallbacks(db) { record in
        try record.updateWithCallbacks(
          db,
          columns: columns,
          conflict: conflict,
          selection: selection,
          fetch: fetch
        )
      }
    }

    func updateWithCallbacks<T>(
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
        let statement = try returningStatement(
          db,
          sql: sql,
          table: Self.databaseTableName,
          selection: selection
        )
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

    mutating func saveRecord<T>(
      _ db: Database,
      conflict: Database.ConflictResolution?,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      try withSaveCallbacks(db) { record in
        let container = try PersistenceContainer(record)
        let key = try primaryKeyValues(db, table: Self.databaseTableName, container: container)
        if key.values.allSatisfy({ !$0.isNull }) {
          do {
            return try record.updateWithCallbacks(
              db,
              columns: Set(container.fields.map(\.0)),
              conflict: conflict,
              selection: selection,
              fetch: fetch
            )
          } catch RecordError.recordNotFound {}
        }
        let inserted = try record.insertWithCallbacks(
          db,
          conflict: conflict,
          selection: selection,
          fetch: fetch
        )
        let result = PersistenceSuccess(persistenceContainer: inserted.0.persistenceContainer)
        return (result, inserted.1)
      }
    }

    mutating func withSaveCallbacks<T>(
      _ db: Database,
      save: (inout Self) throws -> (PersistenceSuccess, T)
    ) throws -> T {
      try willSave(db)
      var success: (PersistenceSuccess, T)?
      try aroundSave(db) {
        guard success == nil else {
          throw callbackMisuse("aroundSave")
        }
        let result = try save(&self)
        success = result
        return result.0
      }
      guard let success else {
        throw callbackMisuse("aroundSave")
      }
      didSave(success.0)
      return success.1
    }

    mutating func withInsertCallbacks<T>(
      _ db: Database,
      insert: (PersistenceContainer) throws -> (InsertionSuccess, T)
    ) throws -> (InsertionSuccess, T) {
      try willInsert(db)
      let container = try PersistenceContainer(self)
      var success: (InsertionSuccess, T)?
      try aroundInsert(db) {
        guard success == nil else {
          throw callbackMisuse("aroundInsert")
        }
        let result = try insert(container)
        success = result
        return result.0
      }
      guard let success else {
        throw callbackMisuse("aroundInsert")
      }
      didInsert(success.0)
      return success
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
    let prefix =
      conflict == .abort
      ? "INSERT INTO \(quoted(table))"
      : "INSERT OR \(conflict.sqlName) INTO \(quoted(table))"
    guard !container.isEmpty else {
      return SQL(sql: prefix + " DEFAULT VALUES")
    }
    let columns = container.fields.map { quoted($0.0) }.joined(separator: ", ")
    let values = Array(repeating: "?", count: container.count).joined(separator: ",")
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
    let keyColumns = try db.primaryKey(table).columns
    let keyValues = keyColumns.map { container[$0]?.databaseValue ?? .null }
    guard keyValues.contains(where: { !$0.isNull }) else {
      throw RecordError.recordNotFound(
        databaseTableName: table,
        key: Dictionary(uniqueKeysWithValues: zip(keyColumns, keyValues))
      )
    }
    // Update requested columns present in the container, except primary key columns, in
    // table column order.
    let requested = Set(columns.map { $0.lowercased() })
      .intersection(container.fields.map { $0.0.lowercased() })
      .subtracting(keyColumns.map { $0.lowercased() })
    var updated = try db.columns(in: table).map(\.name)
      .filter { requested.contains($0.lowercased()) }
    if updated.isEmpty {
      // Update something, so that the change is observable.
      updated = keyColumns
    }
    let values = updated.map { container[$0]?.databaseValue ?? .null }
    let assignments = updated.map { quoted($0) + "=?" }.joined(separator: ", ")
    let predicate = keyColumns.map { quoted($0) + "=?" }.joined(separator: " AND ")
    let prefix =
      conflict == .abort
      ? "UPDATE \(quoted(table))" : "UPDATE OR \(conflict.sqlName) \(quoted(table))"
    return SQL(
      sql: prefix + " SET \(assignments) WHERE \(predicate)",
      arguments: StatementArguments(values + keyValues)
    )
  }

  /// Appends a RETURNING clause qualified with the persisted table.
  func returningStatement(
    _ db: Database,
    sql: SQL,
    table: String,
    selection: [any SQLSelectable]
  ) throws -> Statement {
    var (text, arguments) = try sql.build(db)
    if !selection.isEmpty {
      let alias = TableAliasBase(tableName: table)
      let context = SQLGenerationContext(db, aliases: [alias])
      text +=
        try " RETURNING "
        + selection.map { try $0.sqlSelection.qualified(with: alias).sql(context) }
        .joined(separator: ", ")
      arguments = arguments &+ context.arguments
    }
    let statement = try db.makeStatement(sql: text)
    statement.arguments = arguments
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
      precondition(!selection.isEmpty, "Invalid empty selection")
      return try insertRecord(db, conflict: conflict, selection: selection, fetch: fetch)
    }

    public mutating func insertAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      let source = self
      return try insertAndFetch(db, onConflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try source.missingRecord(db)
        }
        return record
      }
    }

    public func insertAndFetch(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil
    ) throws -> Self where Self: FetchableRecord {
      var copy = self
      return try copy.insertAndFetch(db, onConflict: conflict, as: Self.self)
    }

    public mutating func saveAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      precondition(!selection.isEmpty, "Invalid empty selection")
      return try saveRecord(db, conflict: conflict, selection: selection, fetch: fetch)
    }

    public mutating func saveAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      let source = self
      return try saveAndFetch(db, onConflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try source.missingRecord(db)
        }
        return record
      }
    }

    public func saveAndFetch(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil
    ) throws -> Self where Self: FetchableRecord {
      var copy = self
      return try copy.saveAndFetch(db, onConflict: conflict, as: Self.self)
    }
  }

  extension PersistableRecord {
    public func insertAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T
    ) throws -> T {
      precondition(!selection.isEmpty, "Invalid empty selection")
      var copy = self
      return try copy.insertRecord(db, conflict: conflict, selection: selection, fetch: fetch)
    }

    public func insertAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      try insertAndFetch(db, onConflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try missingRecord(db)
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
      precondition(!selection.isEmpty, "Invalid empty selection")
      var copy = self
      return try copy.saveRecord(db, conflict: conflict, selection: selection, fetch: fetch)
    }

    public func saveAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as returnedType: T.Type
    ) throws -> T {
      try saveAndFetch(db, onConflict: conflict, selection: T.databaseSelection) {
        guard let record = try T.fetchOne($0) else {
          throw try missingRecord(db)
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
      precondition(!selection.isEmpty, "Invalid empty selection")
      return try updateRecord(
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
      precondition(!selection.isEmpty, "Invalid empty selection")
      return try updateRecord(
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
