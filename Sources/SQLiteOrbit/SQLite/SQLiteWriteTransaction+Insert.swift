#if StructuredQueries
  public import StructuredQueriesSQLite

  // Inserting a record without preparing an insert first. Each table's SQL is built once per
  // process and conflict clause, and its statement comes from the connection's cache, so a call
  // costs a lookup and the row's binds rather than building the statement as `Table.insert` does.
  extension SQLiteWriteTransaction {
    /// Inserts a record or draft and returns its rowid.
    ///
    /// Every column but generated ones is written, as `Table.insert { row }` writes them.
    ///
    /// ```swift
    /// try await database.write { transaction in
    ///   let id = try transaction.insert(Reminder.Draft(title: "Buy milk", listID: listID))
    /// }
    /// ```
    ///
    /// - Parameter row: The record or draft to insert.
    /// - Returns: The new row's rowid.
    /// - Throws: A ``SQLiteError`` when the insert fails.
    @discardableResult
    public borrowing func insert<Row: Table>(_ row: Row) throws -> Int64 {
      try runInsert(SQLiteInsertPlans.records(Row.self, onConflict: nil), row)
      return lastInsertedRowID
    }

    /// Inserts a record or draft, replacing any row it conflicts with, and returns its rowid.
    ///
    /// ```swift
    /// try transaction.insert(reminder, onConflict: .replace)
    /// ```
    ///
    /// - Parameters:
    ///   - row: The record or draft to insert.
    ///   - conflict: What to do with a row it conflicts with.
    /// - Returns: The new row's rowid.
    /// - Throws: A ``SQLiteError`` when the insert fails.
    @discardableResult
    public borrowing func insert<Row: Table>(
      _ row: Row,
      onConflict conflict: SQLiteInsertConflict
    ) throws -> Int64 {
      try runInsert(SQLiteInsertPlans.records(Row.self, onConflict: conflict), row)
      return lastInsertedRowID
    }

    /// Inserts a record or draft, or skips or updates the row it conflicts with, and returns the
    /// rowid it inserted.
    ///
    /// ```swift
    /// try transaction.insert(tag, onConflict: .ignore)
    /// ```
    ///
    /// - Parameters:
    ///   - row: The record or draft to insert.
    ///   - conflict: What to do with a row it conflicts with.
    /// - Returns: The new row's rowid, or `nil` when the row was skipped or updated instead.
    /// - Throws: A ``SQLiteError`` when the insert fails.
    @discardableResult
    public borrowing func insert<Row: Table>(
      _ row: Row,
      onConflict conflict: SQLiteUpsertConflict<Row>
    ) throws -> Int64? {
      let plan = try SQLiteInsertPlans.records(Row.self, onConflict: conflict)
      return try sqliteInsertedRowID(on: base.connection, library: base.library) {
        try runInsert(plan, row)
      }
    }

    /// Inserts records or drafts, all or none, and returns how many it inserted.
    ///
    /// A failure leaves none of the rows behind, even when it is caught inside the transaction,
    /// as ``SQLitePreparedInsert/execute(contentsOf:)`` does.
    ///
    /// ```swift
    /// try transaction.insert(contentsOf: reminders)
    /// ```
    ///
    /// - Parameter rows: The records or drafts to insert.
    /// - Returns: The number of rows inserted.
    /// - Throws: A ``SQLiteError`` when an insert fails.
    @inlinable
    @discardableResult
    public borrowing func insert<Row: Table>(contentsOf rows: some Sequence<Row>) throws -> Int {
      // Inlined, so that the sequence is stepped, and its rows bound, in code specialized for
      // them.
      var iterator = rows.makeIterator()
      var next = iterator.next()
      return try insertEach(Row.self, onConflict: nil) {
        try $0.bind(next: &next, from: &iterator)
      }
    }

    /// Inserts records or drafts, replacing any rows they conflict with, all or none, and returns
    /// how many it inserted.
    ///
    /// ```swift
    /// try transaction.insert(contentsOf: reminders, onConflict: .replace)
    /// ```
    ///
    /// - Parameters:
    ///   - rows: The records or drafts to insert.
    ///   - conflict: What to do with a row one conflicts with.
    /// - Returns: The number of rows inserted. A row deleted to make room is not counted.
    /// - Throws: A ``SQLiteError`` when an insert fails.
    @inlinable
    @discardableResult
    public borrowing func insert<Row: Table>(
      contentsOf rows: some Sequence<Row>,
      onConflict conflict: SQLiteInsertConflict
    ) throws -> Int {
      var iterator = rows.makeIterator()
      var next = iterator.next()
      return try insertEach(Row.self, onConflict: conflict) {
        try $0.bind(next: &next, from: &iterator)
      }
    }

    /// Inserts records or drafts, or skips or updates the rows they conflict with, all or none,
    /// and returns how many rows it inserted or updated.
    ///
    /// ```swift
    /// try transaction.insert(contentsOf: incoming, onConflict: .update)
    /// ```
    ///
    /// - Parameters:
    ///   - rows: The records or drafts to insert.
    ///   - conflict: What to do with a row one conflicts with.
    /// - Returns: The number of rows inserted or updated. A skipped row is not counted.
    /// - Throws: A ``SQLiteError`` when an insert fails.
    @inlinable
    @discardableResult
    public borrowing func insert<Row: Table>(
      contentsOf rows: some Sequence<Row>,
      onConflict conflict: SQLiteUpsertConflict<Row>
    ) throws -> Int {
      var iterator = rows.makeIterator()
      var next = iterator.next()
      return try insertEach(Row.self, onConflict: conflict) {
        try $0.bind(next: &next, from: &iterator)
      }
    }

    // What `insert(contentsOf:)` and `insert(contentsOf:onConflict:)` with an insert conflict
    // run, with each row bound by `step`.
    @usableFromInline
    borrowing func insertEach<Row: Table>(
      _ table: Row.Type,
      onConflict conflict: SQLiteInsertConflict?,
      each step: (SQLiteInsertArguments) throws -> SQLiteInsertArguments.Element
    ) throws -> Int {
      let plan = try SQLiteInsertPlans.records(Row.self, onConflict: conflict)
      var statement = try preparedStatement(for: plan)
      return try statement.runInserts(plan, each: step)
    }

    // What `insert(contentsOf:onConflict:)` with an upsert conflict runs, with each row bound by
    // `step`.
    @usableFromInline
    borrowing func insertEach<Row: Table>(
      _ table: Row.Type,
      onConflict conflict: SQLiteUpsertConflict<Row>,
      each step: (SQLiteInsertArguments) throws -> SQLiteInsertArguments.Element
    ) throws -> Int {
      let plan = try SQLiteInsertPlans.records(Row.self, onConflict: conflict)
      var statement = try preparedStatement(for: plan)
      return try statement.runInserts(plan, each: step)
    }

    // Runs a plan's statement once, straight from the connection's cache, without the prepared
    // statement a bulk insert runs, which a single row would pay to make and destroy.
    private borrowing func runInsert<Row>(_ plan: SQLiteInsertPlan, _ row: Row) throws {
      try withOrbitCursor(
        SQLiteRowCursor(
          plan.query,
          binding: { statement, library in
            try withUnsafePointer(to: row) {
              try SQLiteInsertArguments(plan: plan, library: library, statement: statement)
                .bind(row: $0)
            }
          },
          connection: base.connection,
          library: base.library,
          statements: base.statements,
          authorizer: base.authorizer,
          observations: base.observations,
          connectionState: base.connectionState
        )
      ) { cursor in
        while try cursor.next() != nil {}
      }
    }
  }
#endif
