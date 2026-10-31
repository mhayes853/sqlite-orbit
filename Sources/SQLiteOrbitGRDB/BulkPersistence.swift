#if canImport(Foundation) && canImport(Dispatch)
  import SQLiteOrbit

  extension QueryInterfaceRequest {
    private var updateConflictResolution: Database.ConflictResolution {
      (RowDecoder.self as? any MutablePersistableRecord.Type)?
        .persistenceConflictPolicy.conflictResolutionForUpdate ?? .abort
    }

    @discardableResult
    public func deleteAll(_ db: Database) throws -> Int {
      let statement = try SQLQueryGenerator(relation: relation).makeDeleteStatement(db)
      return try executeMutation(db, statement: statement)
    }

    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment]
    ) throws -> Int {
      guard !assignments.isEmpty,
        let statement = try SQLQueryGenerator(relation: relation)
          .makeUpdateStatement(
            db,
            conflict: conflict ?? updateConflictResolution,
            assignments: assignments
          )
      else {
        return 0
      }
      return try executeMutation(db, statement: statement)
    }

    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: ColumnAssignment...
    ) throws -> Int {
      try updateAll(db, onConflict: conflict, assignments)
    }

    private func executeMutation(_ db: Database, statement: Statement) throws -> Int {
      // SQLite's changes() excludes INSTEAD OF triggers. GRDB counts total changes for views,
      // while keeping changes() for tables (notably virtual tables with shadow-table writes).
      let previous = try db.viewExists(table) ? db.untracedTotalChanges() : nil
      try statement.execute()
      return try previous.map { try db.untracedTotalChanges() - $0 } ?? db.changesCount
    }

    public func updateAndFetchStatement(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment],
      selection: [any SQLSelectable]
    ) throws -> Statement {
      precondition(!assignments.isEmpty, "Invalid empty assignments")
      precondition(!selection.isEmpty, "Invalid empty selection")
      guard
        let statement = try SQLQueryGenerator(relation: relation)
          .makeUpdateStatement(
            db,
            conflict: conflict ?? updateConflictResolution,
            assignments: assignments,
            selection: selection
          )
      else {
        throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Invalid empty assignments")
      }
      return statement
    }

    public func deleteAndFetchStatement(_ db: Database, selection: [any SQLSelectable]) throws
      -> Statement
    {
      precondition(!selection.isEmpty, "Invalid empty selection")
      return try SQLQueryGenerator(relation: relation).makeDeleteStatement(db, selection: selection)
    }
  }

  extension QueryInterfaceRequest where RowDecoder: TableRecord {
    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignment: (RowDecoder.DatabaseComponents) throws -> ColumnAssignment
    ) throws -> Int {
      try updateAll(db, onConflict: conflict, [assignment(RowDecoder.databaseComponents)])
    }

    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignments: (RowDecoder.DatabaseComponents) throws -> [ColumnAssignment]
    ) throws -> Int {
      try updateAll(db, onConflict: conflict, assignments(RowDecoder.databaseComponents))
    }

    public func deleteAndFetchStatement(
      _ db: Database,
      select: (RowDecoder.DatabaseComponents) throws -> [any SQLSelectable]
    ) throws -> Statement {
      try deleteAndFetchStatement(db, selection: select(RowDecoder.databaseComponents))
    }

    public func updateAndFetchStatement(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignments: (RowDecoder.DatabaseComponents) throws -> [ColumnAssignment],
      select: (RowDecoder.DatabaseComponents) throws -> [any SQLSelectable]
    ) throws -> Statement {
      try updateAndFetchStatement(
        db,
        onConflict: conflict,
        assignments(RowDecoder.databaseComponents),
        selection: select(RowDecoder.databaseComponents)
      )
    }
  }

  extension Database {
    /// The SQL literal of a value (`'O''Brien'`, `X'666F6F'`), quoted by SQLite without tracing.
    func quotedLiteral(_ value: DatabaseValue) throws -> String {
      if value.isNull { return "NULL" }
      return try translate {
        let cursor = try access.statementCursor(
          SQLiteOrbit.SQL(text: "SELECT QUOTE(?)", bindings: [value.orbitValue])
        )
        defer { try? cursor.close() }
        guard let quoted = try cursor.next()?.first?.value,
          let string = String.fromDatabaseValue(DatabaseValue(quoted))
        else {
          return "NULL"
        }
        return string
      }
    }

    /// `total_changes()` without tracing the query.
    func untracedTotalChanges() throws -> Int {
      try translate {
        let cursor = try access.statementCursor(
          SQLiteOrbit.SQL(text: "SELECT total_changes()", bindings: [])
        )
        defer { try? cursor.close() }
        guard let value = try cursor.next()?.first?.value,
          let count = Int.fromDatabaseValue(DatabaseValue(value))
        else {
          return 0
        }
        return count
      }
    }
  }

  extension QueryInterfaceRequest where RowDecoder: FetchableRecord & TableRecord {
    public func updateAndFetchCursor(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment]
    ) throws -> RecordCursor<RowDecoder> {
      try RowDecoder.fetchCursor(
        updateAndFetchStatement(
          db,
          onConflict: conflict,
          assignments,
          selection: RowDecoder.databaseSelection
        )
      )
    }

    public func updateAndFetchAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment]
    ) throws -> [RowDecoder] {
      try Array(updateAndFetchCursor(db, onConflict: conflict, assignments))
    }

    public func deleteAndFetchCursor(_ db: Database) throws -> RecordCursor<RowDecoder> {
      try RowDecoder.fetchCursor(
        deleteAndFetchStatement(db, selection: RowDecoder.databaseSelection)
      )
    }

    public func deleteAndFetchAll(_ db: Database) throws -> [RowDecoder] {
      try Array(deleteAndFetchCursor(db))
    }
  }

  extension QueryInterfaceRequest where RowDecoder: FetchableRecord & TableRecord & Hashable {
    public func updateAndFetchSet(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment]
    ) throws -> Set<RowDecoder> {
      try Set(updateAndFetchCursor(db, onConflict: conflict, assignments))
    }

    public func deleteAndFetchSet(_ db: Database) throws -> Set<RowDecoder> {
      try Set(deleteAndFetchCursor(db))
    }
  }

  extension QueryInterfaceRequest
  where
    RowDecoder: TableRecord & Identifiable,
    RowDecoder.ID: Hashable & DatabaseValueConvertible
  {
    public func deleteAndFetchIds(_ db: Database) throws -> Set<RowDecoder.ID> {
      let key = try db.primaryKey(RowDecoder.databaseTableName)
      precondition(key.columns.count == 1, "Fetching id requires a single-column primary key")
      let statement = try deleteAndFetchStatement(db, selection: [Column(key.columns[0])])
      return try RowDecoder.ID.fetchSet(statement)
    }
  }

  extension TableRecord {
    @discardableResult
    public static func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment]
    ) throws -> Int {
      try all().updateAll(db, onConflict: conflict, assignments)
    }

    @discardableResult
    public static func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: ColumnAssignment...
    ) throws -> Int {
      try updateAll(db, onConflict: conflict, assignments)
    }

    @discardableResult
    public static func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignment: (DatabaseComponents) throws -> ColumnAssignment
    ) throws -> Int {
      try updateAll(db, onConflict: conflict, [assignment(databaseComponents)])
    }

    @discardableResult
    public static func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignments: (DatabaseComponents) throws -> [ColumnAssignment]
    ) throws -> Int {
      try updateAll(db, onConflict: conflict, assignments(databaseComponents))
    }

    @discardableResult
    public static func deleteAll(_ db: Database) throws -> Int {
      try all().deleteAll(db)
    }
  }

  extension ColumnExpression {
    public static func += (column: Self, value: some SQLExpressible) -> ColumnAssignment {
      column.set(to: column + value)
    }

    public static func -= (column: Self, value: some SQLExpressible) -> ColumnAssignment {
      column.set(to: column - value)
    }

    public static func *= (column: Self, value: some SQLExpressible) -> ColumnAssignment {
      column.set(to: column * value)
    }

    public static func /= (column: Self, value: some SQLExpressible) -> ColumnAssignment {
      column.set(to: column / value)
    }

    public static func &= (column: Self, value: some SQLExpressible) -> ColumnAssignment {
      column.set(to: column & value)
    }

    public static func |= (column: Self, value: some SQLExpressible) -> ColumnAssignment {
      column.set(to: column | value)
    }

    public static func <<= (column: Self, value: some SQLExpressible) -> ColumnAssignment {
      column.set(to: column << value)
    }

    public static func >>= (column: Self, value: some SQLExpressible) -> ColumnAssignment {
      column.set(to: column >> value)
    }

  }
#endif
