#if canImport(Foundation) && canImport(Dispatch)
  extension QueryInterfaceRequest {
    @discardableResult
    public func deleteAll(_ db: Database) throws -> Int {
      try executeMutation(db, statement: mutationStatement(db))
    }

    @discardableResult
    public func updateAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment]
    ) throws -> Int {
      guard !assignments.isEmpty else { return 0 }
      return try executeMutation(
        db,
        statement: mutationStatement(db, assignments: assignments, conflict: conflict)
      )
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
      let previous = try db.viewExists(table) ? db.totalChangesCount : nil
      try statement.execute()
      return previous.map { db.totalChangesCount - $0 } ?? db.changesCount
    }

    public func updateAndFetchStatement(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      _ assignments: [ColumnAssignment],
      selection: [any SQLSelectable]
    ) throws -> Statement {
      precondition(!assignments.isEmpty, "Invalid empty assignments")
      precondition(!selection.isEmpty, "Invalid empty selection")
      return try mutationStatement(
        db,
        assignments: assignments,
        conflict: conflict,
        selection: selection
      )
    }

    public func deleteAndFetchStatement(_ db: Database, selection: [any SQLSelectable]) throws
      -> Statement
    {
      precondition(!selection.isEmpty, "Invalid empty selection")
      return try mutationStatement(db, selection: selection)
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
