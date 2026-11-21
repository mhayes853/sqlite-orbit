#if StructuredQueries
  public import StructuredQueriesSQLite

  /// An `INSERT` into a Structured Queries table, built once and run for row after row.
  ///
  /// Running `Table.insert { row }` builds the statement, with a binding for every value, each
  /// time it runs, which costs many times what inserting the row does. A prepared insert builds
  /// its SQL once, from the table's columns, and binds each row's values straight from the row,
  /// so a loop that inserts one row after another only binds and steps.
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   var insert = try transaction.prepareInsert(Reminder.Draft.self)
  ///   for draft in drafts {
  ///     let id = try insert.execute(draft)
  ///   }
  /// }
  /// ```
  ///
  /// A record insert, prepared with ``SQLiteWriteTransaction/prepareInsert(_:onConflict:)``,
  /// takes a record or draft for each run and writes every column but generated ones. A partial
  /// insert, prepared with ``SQLiteWriteTransaction/prepareInsert(_:onConflict:columns:)``, writes
  /// only the columns it lists and takes a value for each of them:
  ///
  /// ```swift
  /// var add = try transaction.prepareInsert(Reminder.self) { ($0.title, $0.listID) }
  /// try add.execute("Buy milk", listID)
  /// try add.execute(contentsOf: [("Eggs", listID), ("Bread", listID)])
  /// ```
  ///
  /// The SQL and the values a run binds are the ones `Table.insert` builds for the same row, so a
  /// run writes exactly what the query builder's statement would.
  ///
  /// Every run of a prepared insert inserts a row, which is why it returns the row's rowid. An
  /// insert that may skip a conflicting row or update it instead is a ``SQLitePreparedUpsert``.
  ///
  /// The insert is valid until the transaction that prepared it ends, and is noncopyable and
  /// nonescapable, as a ``SQLitePreparedStatement`` is, whose statement it runs: it reports what it
  /// changes to observers, and refuses to run across an authorization scope boundary, in the same
  /// way.
  public struct SQLitePreparedInsert<Row: Table, each Input>: ~Copyable, ~Escapable {
    /// The SQL each run executes, with a parameter for each value.
    ///
    /// ```swift
    /// let insert = try transaction.prepareInsert(Reminder.self) { ($0.title, $0.listID) }
    /// print(insert.sql)  // INSERT INTO "reminders" ("title", "listID") VALUES (?, ?)
    /// ```
    public let sql: String

    // Private, which keeps Swift 6.3 from synthesizing a read accessor for the statement. It
    // copies the noncopyable statement, and fails to compile.
    private var statement: SQLitePreparedStatement
    private let plan: SQLiteInsertPlan

    @_lifetime(copy statement)
    init(statement: consuming SQLitePreparedStatement, plan: SQLiteInsertPlan) {
      self.sql = plan.sql
      self.statement = statement
      self.plan = plan
    }

    /// Inserts a row and returns its rowid.
    ///
    /// A record insert takes the record or draft to insert, and a partial insert a value for each
    /// column it lists, in order.
    ///
    /// ```swift
    /// var insert = try transaction.prepareInsert(Reminder.Draft.self)
    /// let id = try insert.execute(Reminder.Draft(title: "Buy milk", listID: listID))
    /// ```
    ///
    /// - Parameter input: The row's values.
    /// - Returns: The new row's rowid, which for a table without one, declared `WITHOUT ROWID`,
    ///   is whatever SQLite reported before the run.
    /// - Throws: A ``SQLiteError`` when the insert fails, or whatever a value throws converting
    ///   to one SQLite stores.
    @inlinable
    @discardableResult
    public mutating func execute(_ input: repeat each Input) throws -> Int64 {
      // Inlined, so that the values are gathered into one row in code specialized for their
      // types.
      let row = (repeat each input)
      return try withUnsafePointer(to: row) { try run(row: $0) }
    }

    // What `execute(_:)` runs, with the row at `row`.
    @usableFromInline
    mutating func run(row: UnsafeRawPointer) throws -> Int64 {
      try statement.runInsert(plan, row: row)
      return statement.lastInsertedRowID
    }

    /// Inserts a row for each element, all or none, and returns how many it inserted.
    ///
    /// A failure leaves none of the elements' rows behind, even when it is caught inside the
    /// transaction, and what the transaction wrote before is kept. Two or more elements are
    /// inserted inside a savepoint of their own, which nests inside any savepoint of the caller's.
    /// The sequence is read one element at a time, so a lazy one is never collected into an
    /// array.
    ///
    /// ```swift
    /// var insert = try transaction.prepareInsert(Reminder.self)
    /// try insert.execute(contentsOf: reminders)
    /// ```
    ///
    /// - Parameter inputs: The rows' values: records or drafts for a record insert, or a tuple of
    ///   values for each row of a partial insert.
    /// - Returns: The number of rows inserted. A row a `.replace` insert deletes to make room is
    ///   not counted.
    /// - Throws: A ``SQLiteError`` when an insert fails, or whatever a value throws converting
    ///   to one SQLite stores.
    @inlinable
    @discardableResult
    public mutating func execute(contentsOf inputs: some Sequence<(repeat each Input)>) throws
      -> Int
    {
      // Inlined, so that the sequence is stepped, and its elements bound, in code specialized
      // for them. The iterator is read one element ahead, which tells the last element apart.
      var iterator = inputs.makeIterator()
      var next = iterator.next()
      return try execute(each: { try $0.bind(next: &next, from: &iterator) })
    }

    // What `execute(contentsOf:)` runs, with each element bound by `step`.
    @usableFromInline
    mutating func execute(
      each step: (SQLiteInsertArguments) throws -> SQLiteInsertArguments.Element
    ) throws -> Int {
      try statement.runInserts(plan, each: step)
    }
  }

  /// An `INSERT` into a Structured Queries table that may skip a conflicting row or update it
  /// instead, built once and run for row after row.
  ///
  /// An upsert is prepared like a ``SQLitePreparedInsert``, with a ``SQLiteUpsertConflict``
  /// saying what to do with a row whose key, or other unique column, matches one already in the
  /// table:
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   var save = try transaction.prepareInsert(Reminder.self, onConflict: .update)
  ///   try save.execute(contentsOf: incoming.lazy.map(Reminder.init))
  ///
  ///   var rename = try transaction.prepareInsert(Reminder.self, onConflict: .update) {
  ///     ($0.id, $0.title)
  ///   }
  ///   try rename.execute(id, "Buy oat milk")
  /// }
  /// ```
  ///
  /// A run that skips or updates a row inserts none, so it returns `nil` rather than a rowid, and
  /// leaves ``SQLiteWriteTransaction/lastInsertedRowID`` as it was.
  ///
  /// The upsert is valid until the transaction that prepared it ends, and is noncopyable and
  /// nonescapable, as a ``SQLitePreparedStatement`` is, whose statement it runs.
  public struct SQLitePreparedUpsert<Row: Table, each Input>: ~Copyable, ~Escapable {
    /// The SQL each run executes, with a parameter for each value.
    ///
    /// ```swift
    /// let save = try transaction.prepareInsert(Tag.self, onConflict: .ignore)
    /// print(save.sql)  // INSERT INTO "tags" ("title") VALUES (?) ON CONFLICT DO NOTHING
    /// ```
    public let sql: String

    // Private, which keeps Swift 6.3 from synthesizing a read accessor for the statement. It
    // copies the noncopyable statement, and fails to compile.
    private var statement: SQLitePreparedStatement
    private let plan: SQLiteInsertPlan

    @_lifetime(copy statement)
    init(statement: consuming SQLitePreparedStatement, plan: SQLiteInsertPlan) {
      self.sql = plan.sql
      self.statement = statement
      self.plan = plan
    }

    /// Inserts a row, or skips or updates the row it conflicts with, and returns the rowid it
    /// inserted.
    ///
    /// ```swift
    /// var save = try transaction.prepareInsert(Tag.self, onConflict: .ignore)
    /// if let id = try save.execute(tag) {
    ///   print("inserted \(id)")
    /// }
    /// ```
    ///
    /// - Parameter input: The row's values.
    /// - Returns: The new row's rowid, or `nil` when the run skipped or updated a row instead. A
    ///   table declared `WITHOUT ROWID` has no rowid, so a run into one returns `nil`.
    /// - Throws: A ``SQLiteError`` when the insert fails, such as for a `NOT NULL` column left
    ///   without a value, which no conflict clause skips, or whatever a value throws converting to
    ///   one SQLite stores.
    @inlinable
    @discardableResult
    public mutating func execute(_ input: repeat each Input) throws -> Int64? {
      // Inlined, so that the values are gathered into one row in code specialized for their
      // types.
      let row = (repeat each input)
      return try withUnsafePointer(to: row) { try run(row: $0) }
    }

    // What `execute(_:)` runs, with the row at `row`.
    @usableFromInline
    mutating func run(row: UnsafeRawPointer) throws -> Int64? {
      try statement.runUpsert(plan, row: row)
    }

    /// Inserts a row for each element, or skips or updates the row it conflicts with, all or
    /// none, and returns how many rows it inserted or updated.
    ///
    /// A failure leaves nothing of the elements behind, even when it is caught inside the
    /// transaction, and what the transaction wrote before is kept, as
    /// ``SQLitePreparedInsert/execute(contentsOf:)`` does.
    ///
    /// ```swift
    /// var save = try transaction.prepareInsert(Reminder.self, onConflict: .update)
    /// let saved = try save.execute(contentsOf: reminders)
    /// ```
    ///
    /// - Parameter inputs: The rows' values: records or drafts for a record insert, or a tuple of
    ///   values for each row of a partial insert.
    /// - Returns: The number of rows inserted or updated. A skipped row is not counted.
    /// - Throws: A ``SQLiteError`` when an insert fails, or whatever a value throws converting
    ///   to one SQLite stores.
    @inlinable
    @discardableResult
    public mutating func execute(contentsOf inputs: some Sequence<(repeat each Input)>) throws
      -> Int
    {
      // Inlined, so that the sequence is stepped, and its elements bound, in code specialized
      // for them. The iterator is read one element ahead, which tells the last element apart.
      var iterator = inputs.makeIterator()
      var next = iterator.next()
      return try execute(each: { try $0.bind(next: &next, from: &iterator) })
    }

    // What `execute(contentsOf:)` runs, with each element bound by `step`.
    @usableFromInline
    mutating func execute(
      each step: (SQLiteInsertArguments) throws -> SQLiteInsertArguments.Element
    ) throws -> Int {
      try statement.runInserts(plan, each: step)
    }
  }

  /// What an insert does with a row that conflicts with one already in the table, while still
  /// inserting it.
  ///
  /// ```swift
  /// var insert = try transaction.prepareInsert(Reminder.self, onConflict: .replace)
  /// ```
  public struct SQLiteInsertConflict: Sendable {
    let conflict: SQLiteInsertPlan.Conflict

    // What the conveniences' plan cache tells this clause apart by. No clause at all is 0.
    var code: UInt8 { 1 }

    /// Deletes every row the new row conflicts with, on its key or on any other unique column,
    /// and then inserts it: `INSERT OR REPLACE`.
    ///
    /// The deleted rows run their `ON DELETE` foreign key actions when foreign keys are enforced,
    /// but not their delete triggers, unless `recursive_triggers` is on.
    public static var replace: Self { Self(conflict: .replace) }
  }

  /// What an upsert does with a row that conflicts with one already in the table instead of
  /// inserting it.
  ///
  /// ```swift
  /// try transaction.insert(tag, onConflict: .ignore)
  /// var save = try transaction.prepareInsert(Reminder.self, onConflict: .update)
  /// ```
  public struct SQLiteUpsertConflict<Row: Table>: Sendable {
    let isUpdate: Bool

    // Read only when a plan is built, so naming the conflict clause costs nothing.
    let keyColumns: @Sendable () -> [String]

    var conflict: SQLiteInsertPlan.Conflict {
      isUpdate ? .update(keyColumns: keyColumns()) : .ignore
    }

    // What the conveniences' plan cache tells this clause apart by.
    var code: UInt8 { isUpdate ? 3 : 2 }

    /// Skips a row whose key, or other unique column, matches a row already in the table:
    /// `ON CONFLICT DO NOTHING`.
    ///
    /// Only a uniqueness conflict is skipped. A row that breaks a `NOT NULL` or `CHECK`
    /// constraint still fails the insert, which `INSERT OR IGNORE` would skip without a word.
    public static var ignore: Self { Self(isUpdate: false, keyColumns: { [] }) }
  }

  extension SQLiteUpsertConflict where Row: PrimaryKeyedTable {
    /// Updates the row whose primary key matches the new row's with the new row's other values:
    /// `ON CONFLICT (<primary key>) DO UPDATE SET <column> = excluded.<column>, …`.
    ///
    /// Only the columns the insert writes are updated, so a partial insert leaves a conflicting
    /// row's other columns as they were. It must write the primary key. A conflict on any other
    /// unique column still fails the insert.
    public static var update: Self {
      Self(isUpdate: true, keyColumns: { Row.columns.primaryKey._names })
    }
  }

  extension SQLiteUpsertConflict where Row: TableDraft, Row.SourceTable: PrimaryKeyedTable {
    /// Updates the row whose primary key matches the draft's with the draft's other values.
    ///
    /// A draft without a primary key never conflicts on it, since a `NULL` key matches no row, so
    /// it is inserted.
    public static var update: Self {
      Self(isUpdate: true, keyColumns: { Row.SourceTable.columns.primaryKey._names })
    }
  }

  // MARK: - Preparing

  extension SQLiteWriteTransaction {
    /// Prepares an insert of records or drafts that writes every column but generated ones.
    ///
    /// ```swift
    /// try await database.write { transaction in
    ///   var insert = try transaction.prepareInsert(Reminder.Draft.self)
    ///   for draft in drafts {
    ///     try insert.execute(draft)
    ///   }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - table: The record or draft type to insert.
    ///   - conflict: What to do with a row that conflicts with one already in the table: `nil`
    ///     to fail the insert, or ``SQLiteInsertConflict/replace`` to replace it.
    /// - Returns: An insert valid until this transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be compiled.
    @_lifetime(borrow self)
    public borrowing func prepareInsert<Row: Table>(
      _ table: Row.Type,
      onConflict conflict: SQLiteInsertConflict? = nil
    ) throws -> SQLitePreparedInsert<Row, Row> {
      let plan = try SQLiteInsertPlans.records(
        Row.self,
        code: conflict?.code ?? 0,
        conflict: conflict?.conflict ?? .none
      )
      return SQLitePreparedInsert(statement: try preparedStatement(for: plan), plan: plan)
    }

    /// Prepares an insert of records or drafts that skips or updates a conflicting row.
    ///
    /// ```swift
    /// var save = try transaction.prepareInsert(Reminder.self, onConflict: .update)
    /// for reminder in incoming {
    ///   try save.execute(reminder)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - table: The record or draft type to insert.
    ///   - conflict: What to do with a row that conflicts with one already in the table.
    /// - Returns: An upsert valid until this transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be compiled.
    @_lifetime(borrow self)
    public borrowing func prepareInsert<Row: Table>(
      _ table: Row.Type,
      onConflict conflict: SQLiteUpsertConflict<Row>
    ) throws -> SQLitePreparedUpsert<Row, Row> {
      let plan = try SQLiteInsertPlans.records(
        Row.self,
        code: conflict.code,
        conflict: conflict.conflict
      )
      return SQLitePreparedUpsert(statement: try preparedStatement(for: plan), plan: plan)
    }

    /// Prepares an insert that writes only the listed columns, from a value for each.
    ///
    /// The columns are listed as they are for `Table.insert`, and a column group writes each of
    /// its columns. A column left out takes its default value.
    ///
    /// ```swift
    /// var add = try transaction.prepareInsert(Reminder.self) { ($0.title, $0.listID) }
    /// try add.execute("Buy milk", listID)
    /// ```
    ///
    /// - Parameters:
    ///   - table: The table to insert into.
    ///   - conflict: What to do with a row that conflicts with one already in the table: `nil`
    ///     to fail the insert, or ``SQLiteInsertConflict/replace`` to replace it.
    ///   - columns: The columns to write, in the order a run takes their values.
    /// - Returns: An insert valid until this transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be compiled, or one with the code
    ///   ``SQLiteResultCode/misuse`` for a column whose value is not one value per column, such
    ///   as an optional column group.
    @_lifetime(borrow self)
    public borrowing func prepareInsert<
      Row: Table,
      V1: _TableColumnExpression,
      each V2: _TableColumnExpression
    >(
      _ table: Row.Type,
      onConflict conflict: SQLiteInsertConflict? = nil,
      columns: (Row.TableColumns) -> (V1, repeat each V2)
    ) throws -> SQLitePreparedInsert<Row, V1.Value.QueryOutput, repeat (each V2).Value.QueryOutput>
    {
      let plan = try SQLiteInsertPlan(
        Row.self,
        columns: columns,
        conflict: conflict?.conflict ?? .none
      )
      return SQLitePreparedInsert(statement: try preparedStatement(for: plan), plan: plan)
    }

    /// Prepares an insert that writes only the listed columns, from a value for each, and skips
    /// or updates a conflicting row.
    ///
    /// An update only changes the listed columns of the conflicting row, and must list the
    /// primary key. SQLite checks a row's `NOT NULL` constraints before it looks for a conflict,
    /// so a column left out must have a default even when every run updates an existing row.
    ///
    /// ```swift
    /// var rename = try transaction.prepareInsert(Reminder.self, onConflict: .update) {
    ///   ($0.id, $0.title)
    /// }
    /// try rename.execute(id, "Buy oat milk")
    /// ```
    ///
    /// - Parameters:
    ///   - table: The table to insert into.
    ///   - conflict: What to do with a row that conflicts with one already in the table.
    ///   - columns: The columns to write, in the order a run takes their values.
    /// - Returns: An upsert valid until this transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be compiled, or one with the code
    ///   ``SQLiteResultCode/misuse`` for an update that does not list the primary key, or for a
    ///   column whose value is not one value per column.
    @_lifetime(borrow self)
    public borrowing func prepareInsert<
      Row: Table,
      V1: _TableColumnExpression,
      each V2: _TableColumnExpression
    >(
      _ table: Row.Type,
      onConflict conflict: SQLiteUpsertConflict<Row>,
      columns: (Row.TableColumns) -> (V1, repeat each V2)
    ) throws -> SQLitePreparedUpsert<Row, V1.Value.QueryOutput, repeat (each V2).Value.QueryOutput>
    {
      let plan = try SQLiteInsertPlan(Row.self, columns: columns, conflict: conflict.conflict)
      return SQLitePreparedUpsert(statement: try preparedStatement(for: plan), plan: plan)
    }

    // The plan's statement, from the connection's cache, as a prepared statement for its runs.
    @_lifetime(borrow self)
    borrowing func preparedStatement(for plan: SQLiteInsertPlan) throws -> SQLitePreparedStatement {
      let statement = try SQLitePreparedStatement(
        plan.query,
        cached: true,
        requiresReadOnly: false,
        connection: base.connection,
        library: base.library,
        statements: base.statements,
        authorizer: base.authorizer,
        observations: base.observations,
        connectionState: base.connectionState
      )
      guard statement.parameterCount == plan.parameterCount else {
        throw SQLiteError(
          code: .misuse,
          message: """
            the insert binds \(plan.parameterCount) values, but SQLite counts \
            \(statement.parameterCount) parameters
            """,
          sql: plan.sql
        )
      }
      return statement
    }
  }
#endif
