/// A statement compiled once and run many times with different values.
///
/// Running SQL through a transaction builds its text, finds its statement in the connection's
/// cache and binds the values interpolated into it, every time it runs. A prepared statement does
/// the first two once, when it is prepared, so a loop that runs the same statement over and over
/// only binds each run's values and steps.
///
/// ```swift
/// try await database.write { transaction in
///   var insert = try transaction.prepare("INSERT INTO items (a, b, c) VALUES (?, ?, ?)")
///   for item in items {
///     try insert.execute(item.a, item.b, item.c)
///   }
/// }
/// ```
///
/// The statement's parameters are the placeholders written in its SQL: `?`, `?NNN`, `:name`,
/// `@name` or `$name`. Each run takes one argument for every parameter, bound by position from
/// the first, so a run never reuses a value left over from the one before it. Values interpolated
/// into the SQL would be bound only once, so ``SQLiteReadTransaction/prepare(_:cached:)`` refuses
/// them.
///
/// The statement is valid until the transaction that prepared it ends: like the transaction, it
/// is noncopyable and nonescapable. Dropping it gives its statement back to the connection's
/// cache, so preparing the same SQL in a later transaction reuses it. A run's cursor holds the
/// statement exclusively, which is why every run is `mutating`: running the statement again while
/// one of its cursors is open, or from inside its own `fetchAll` transform, does not compile.
///
/// Each run reports what it reads and changes to observers, as running the same SQL through the
/// transaction would. A statement prepared before an authorization scope boundary, entered or
/// left with ``SQLiteReadTransaction/withAuthorization(_:perform:)``, refuses to run on the other
/// side of it, as a cursor carried across one does.
public struct SQLitePreparedStatement<Access: OrbitDatabaseAccess>: ~Copyable, ~Escapable {
  /// The SQL the statement was compiled from.
  ///
  /// ```swift
  /// let insert = try transaction.prepare("INSERT INTO items (a) VALUES (?)")
  /// print(insert.sql)  // INSERT INTO items (a) VALUES (?)
  /// ```
  public let sql: String

  /// How many arguments each run takes: the number of parameters SQLite counts in the SQL.
  ///
  /// SQLite counts a numbered or named parameter used more than once, such as `?1` written twice,
  /// once, and counts `?3` alone as three parameters. SQL that holds no statement has none.
  ///
  /// ```swift
  /// let insert = try transaction.prepare("INSERT INTO items (a, b) VALUES (?, ?)")
  /// print(insert.parameterCount)  // 2
  /// ```
  public let parameterCount: Int

  let library: UnsafePointer<SQLiteLibrary>
  let connection: OpaquePointer
  let statements: SQLiteStatementCache
  let authorizer: SQLiteAuthorizerDispatcher
  let observations: SQLiteConnectionEvents
  let connectionState: SQLiteConnectionState?

  // The scope the statement was prepared and authorized under. A run in any other refuses to step.
  let authorizationGeneration: UInt64

  // What a statement lent by the cache is given back under, or `nil` for one compiled for this
  // prepared statement alone.
  let loan: SQLiteStatementLoan?

  // What each run steps, shared with the run's cursor so metadata it refreshes outlives it, or
  // `nil` for SQL that holds no statement, whose runs produce no rows.
  let state: SQLitePreparedStatementState?

  @_lifetime(borrow statements)
  init(
    _ query: SQL,
    cached: Bool,
    requiresReadOnly: Bool,
    connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    statements: borrowing SQLiteStatementCache,
    authorizer: SQLiteAuthorizerDispatcher,
    observations: SQLiteConnectionEvents,
    connectionState: SQLiteConnectionState?
  ) throws {
    // Every run binds every parameter from its own arguments, so a value interpolated into the
    // SQL would be overwritten on the first run, or shift each run's arguments along.
    for part in try query.validatedParts() {
      switch part {
      case .text: continue
      case .binding: throw Self.interpolatedValueError(sql: query.text)
      case .statement(_, let bindings):
        guard bindings.isEmpty else { throw Self.interpolatedValueError(sql: query.text) }
      }
    }
    let sql: String
    let statement: SQLiteCompiledStatement?
    let loan: SQLiteStatementLoan?
    if cached {
      let checkedOut = try statements.checkOut(query, requiresReadOnly: requiresReadOnly)
      statement = checkedOut.statement
      loan = checkedOut.loan
      sql = checkedOut.loan.sql
    } else {
      loan = nil
      sql = query.text
      statement = try statements.prepare(sql, requiresReadOnly: requiresReadOnly)
    }
    self.sql = sql
    self.loan = loan
    self.parameterCount =
      statement.map { Int(library.pointee.bindings.parameterCount($0.pointer)) } ?? 0
    self.state = statement.map(SQLitePreparedStatementState.init)
    self.library = library
    self.connection = connection
    self.statements = copy statements
    self.authorizer = authorizer
    self.authorizationGeneration = authorizer.generation
    self.observations = observations
    self.connectionState = connectionState
  }

  deinit {
    guard let state else { return }
    // No run's cursor can still be open, since each borrows the statement exclusively, so the
    // statement is not partway through a run.
    if let loan {
      statements.checkIn(state.statement, loan: loan)
    } else {
      _ = library.pointee.statements.execution.finalize(state.statement.pointer)
    }
  }

  private static func interpolatedValueError(sql: String) -> SQLiteError {
    SQLiteError(
      code: .misuse,
      message: """
        a prepared statement takes its values when it runs; write a parameter such as ? in place \
        of each interpolated value
        """,
      sql: sql
    )
  }

  // Refuses a run with the wrong number of arguments before anything is bound. A run rebinds
  // every parameter without clearing the last run's values, so a missing argument would silently
  // reuse whatever the run before it bound.
  private func checkArgumentCount(_ count: Int) throws {
    guard count == parameterCount else {
      throw SQLiteError(
        code: .range,
        message: "the statement takes \(parameterCount) arguments, but was run with \(count)",
        sql: sql
      )
    }
  }

  // Readies the statement for a run's arguments, and returns it, or `nil` when the SQL holds no
  // statement. A run's cursor resets the statement when it is destroyed, but Swift may destroy it
  // only after the next run has begun, so a statement still partway through a run is reset here.
  private func beginRun() -> OpaquePointer? {
    guard let state else { return nil }
    let statement = state.statement.pointer
    if state.needsReset {
      _ = library.pointee.statements.execution.reset(statement)
      state.needsReset = false
    }
    return statement
  }

  mutating func bindArguments<each Argument: ConvertibleToOrbitDatabaseValue>(
    _ arguments: repeat each Argument
  ) throws {
    var count = 0
    for _ in repeat each arguments { count += 1 }
    try checkArgumentCount(count)
    guard let statement = beginRun() else { return }
    var index: Int32 = 1
    for argument in repeat each arguments {
      try bind(argument.orbitDatabaseValue(), to: statement, at: index, library: library)
      index += 1
    }
  }

  mutating func bindArguments(_ bindings: [OrbitDatabaseValue]) throws {
    try checkArgumentCount(bindings.count)
    guard let statement = beginRun() else { return }
    for (offset, value) in bindings.enumerated() {
      try bind(value, to: statement, at: Int32(offset + 1), library: library)
    }
  }

  // A cursor over a run whose arguments are bound. It is made without throwing, so a run that
  // fails to bind has thrown before any cursor exists.
  @_lifetime(&self)
  mutating func runCursor() -> SQLiteRowCursor {
    if let state {
      state.run &+= 1
      state.needsReset = true
    }
    return SQLiteRowCursor(
      running: state,
      sql: sql,
      authorizationGeneration: authorizationGeneration,
      connection: connection,
      library: library,
      statements: statements,
      authorizer: authorizer,
      observations: observations,
      connectionState: connectionState
    )
  }
}

// The statement a prepared statement runs, in a box its runs' cursors share. A cursor that finds
// the statement recompiled, or the schema changed, on its first step records the refreshed
// metadata here, so later runs report the regions the statement reads now, and the box tracks
// which run is the latest, so a cursor destroyed late never resets a later run.
final class SQLitePreparedStatementState {
  var statement: SQLiteCompiledStatement

  // Counts the runs, so a cursor can tell whether its run is still the latest.
  var run: UInt64 = 0

  // Whether a run's cursor may have stepped the statement without resetting it yet.
  var needsReset = false

  init(_ statement: SQLiteCompiledStatement) {
    self.statement = statement
  }

  // Resets the statement when a run's cursor ends, unless a later run has begun. Swift ends a
  // cursor's borrow of its prepared statement at the cursor's last use, but destroys the cursor
  // at the end of its scope, by which time the next run may be under way. The bindings stay
  // either way, since every run rebinds every parameter. Kept out of line, since the cursor's
  // deinit is inlined wherever any cursor ends.
  @inline(never)
  func finishRun(_ run: UInt64, library: UnsafePointer<SQLiteLibrary>) {
    guard run == self.run else { return }
    _ = library.pointee.statements.execution.reset(statement.pointer)
    needsReset = false
  }

}

// MARK: - Preparing

extension SQLiteReadTransaction {
  /// Compiles a statement once, to run many times with different values.
  ///
  /// Write a parameter in the SQL, such as `?`, for each value a run supplies. The SQL must only
  /// read, and is refused with ``SQLiteResultCode/readOnly`` when it may write.
  ///
  /// ```swift
  /// try await database.read { transaction in
  ///   var byList = try transaction.prepare(
  ///     "SELECT * FROM reminders WHERE list_id = ? ORDER BY title"
  ///   )
  ///   for list in lists {
  ///     groups[list.id] = try byList.fetchAll(list.id, as: Reminder.self)
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to compile. It may splice in text with `\(raw:)` or `\(quote:)`, but not
  ///     values, which a run supplies instead.
  ///   - cached: Whether the statement may come from, and goes back to, the connection's cache of
  ///     prepared statements. Pass `false` for a statement prepared only once.
  /// - Returns: A statement valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the SQL cannot be compiled, may write, or has values
  ///   interpolated into it, which is refused with ``SQLiteResultCode/misuse``.
  @_lifetime(borrow self)
  public borrowing func prepare(
    _ sql: SQL,
    cached: Bool = true
  ) throws -> SQLitePreparedStatement<OrbitDatabaseReadAccess> {
    try SQLitePreparedStatement(
      sql,
      cached: cached,
      requiresReadOnly: true,
      connection: connection,
      library: library,
      statements: statements,
      authorizer: authorizer,
      observations: observations,
      connectionState: connectionState
    )
  }
}

extension SQLiteWriteTransaction {
  /// Compiles a statement once, to run many times with different values.
  ///
  /// Write a parameter in the SQL, such as `?`, for each value a run supplies. A write
  /// transaction may write, so the statement is not held to reading.
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   var insert = try transaction.prepare("INSERT INTO items (a, b, c) VALUES (?, ?, ?)")
  ///   for item in items {
  ///     try insert.execute(item.a, item.b, item.c)
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: The SQL to compile. It may splice in text with `\(raw:)` or `\(quote:)`, but not
  ///     values, which a run supplies instead.
  ///   - cached: Whether the statement may come from, and goes back to, the connection's cache of
  ///     prepared statements. Pass `false` for a statement prepared only once.
  /// - Returns: A statement valid until this transaction ends.
  /// - Throws: A ``SQLiteError`` when the SQL cannot be compiled, or has values interpolated into
  ///   it, which is refused with ``SQLiteResultCode/misuse``.
  @_lifetime(borrow self)
  public borrowing func prepare(
    _ sql: SQL,
    cached: Bool = true
  ) throws -> SQLitePreparedStatement<OrbitDatabaseWriteAccess> {
    try SQLitePreparedStatement(
      sql,
      cached: cached,
      requiresReadOnly: false,
      connection: base.connection,
      library: base.library,
      statements: base.statements,
      authorizer: base.authorizer,
      observations: base.observations,
      connectionState: base.connectionState
    )
  }
}

// MARK: - Running

extension SQLitePreparedStatement {
  /// Runs the statement with the given arguments and lends a cursor over the rows it returns.
  ///
  /// The cursor holds the statement until it is dropped, and a cursor dropped before its last row
  /// leaves the statement ready to run again.
  ///
  /// ```swift
  /// var titles = try transaction.prepare("SELECT title FROM reminders WHERE list_id = ?")
  /// var cursor = try titles.rowCursor(listID)
  /// while var row = try cursor.next() {
  ///   print(row[0].textValue ?? "")
  /// }
  /// ```
  ///
  /// - Parameter arguments: One value for each of the statement's parameters, in order.
  /// - Returns: A cursor over the run's rows.
  /// - Throws: A ``SQLiteError`` with the code ``SQLiteResultCode/range`` when the arguments do
  ///   not match ``parameterCount``, or whatever an argument throws converting to a value.
  @_lifetime(&self)
  public mutating func rowCursor<each Argument: ConvertibleToOrbitDatabaseValue>(
    _ arguments: repeat each Argument
  ) throws -> SQLiteRowCursor {
    try bindArguments(repeat each arguments)
    return runCursor()
  }

  /// Runs a statement that has no parameters and lends a cursor over the rows it returns.
  ///
  /// ```swift
  /// var all = try transaction.prepare("SELECT title FROM reminders")
  /// var cursor = try all.rowCursor()
  /// ```
  ///
  /// - Returns: A cursor over the run's rows.
  /// - Throws: A ``SQLiteError`` with the code ``SQLiteResultCode/range`` when the statement has
  ///   parameters.
  @_lifetime(&self)
  public mutating func rowCursor() throws -> SQLiteRowCursor {
    // Spelled out, rather than left to the variadic overload, because Swift 6.3 crashes compiling
    // a call that passes an empty pack to a method whose result depends on `self`.
    try bindArguments()
    return runCursor()
  }

  /// Runs the statement with values gathered at runtime and lends a cursor over the rows it
  /// returns.
  ///
  /// ```swift
  /// var cursor = try statement.rowCursor(bindings: [.integer(listID), .text("Milk")])
  /// ```
  ///
  /// - Parameter bindings: One value for each of the statement's parameters, in order.
  /// - Returns: A cursor over the run's rows.
  /// - Throws: A ``SQLiteError`` with the code ``SQLiteResultCode/range`` when the values do not
  ///   match ``parameterCount``.
  @_lifetime(&self)
  public mutating func rowCursor(bindings: [OrbitDatabaseValue]) throws -> SQLiteRowCursor {
    try bindArguments(bindings)
    return runCursor()
  }

  /// Runs the statement with the given arguments and lends a cursor that initializes a value from
  /// each row.
  ///
  /// ```swift
  /// var byList = try transaction.prepare("SELECT * FROM reminders WHERE list_id = ?")
  /// var reminders = try byList.fetchCursor(listID, as: Reminder.self)
  /// while let reminder = try reminders.next() {
  ///   print(reminder.title)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - arguments: One value for each of the statement's parameters, in order.
  ///   - type: The type to initialize from each row.
  /// - Returns: A cursor over the run's values.
  /// - Throws: A ``SQLiteError`` with the code ``SQLiteResultCode/range`` when the arguments do
  ///   not match ``parameterCount``, or whatever an argument throws converting to a value.
  @_lifetime(&self)
  public mutating func fetchCursor<
    each Argument: ConvertibleToOrbitDatabaseValue,
    Value: ConvertibleFromOrbitDatabaseRow
  >(
    _ arguments: repeat each Argument,
    as type: Value.Type
  ) throws -> OrbitDatabaseRowDecodingCursor<SQLiteRowCursor, Value> {
    try bindArguments(repeat each arguments)
    return OrbitDatabaseRowDecodingCursor(base: runCursor())
  }

  /// Runs a statement that has no parameters and lends a cursor that initializes a value from
  /// each row.
  ///
  /// ```swift
  /// var all = try transaction.prepare("SELECT * FROM reminders")
  /// var reminders = try all.fetchCursor(as: Reminder.self)
  /// ```
  ///
  /// - Parameter type: The type to initialize from each row.
  /// - Returns: A cursor over the run's values.
  /// - Throws: A ``SQLiteError`` with the code ``SQLiteResultCode/range`` when the statement has
  ///   parameters.
  @_lifetime(&self)
  public mutating func fetchCursor<Value: ConvertibleFromOrbitDatabaseRow>(
    as type: Value.Type
  ) throws -> OrbitDatabaseRowDecodingCursor<SQLiteRowCursor, Value> {
    // Spelled out for the same reason as `rowCursor()`.
    try bindArguments()
    return OrbitDatabaseRowDecodingCursor(base: runCursor())
  }

  /// Runs the statement with values gathered at runtime and lends a cursor that initializes a
  /// value from each row.
  ///
  /// ```swift
  /// var reminders = try byList.fetchCursor(bindings: [.integer(listID)], as: Reminder.self)
  /// ```
  ///
  /// - Parameters:
  ///   - bindings: One value for each of the statement's parameters, in order.
  ///   - type: The type to initialize from each row.
  /// - Returns: A cursor over the run's values.
  /// - Throws: A ``SQLiteError`` with the code ``SQLiteResultCode/range`` when the values do not
  ///   match ``parameterCount``.
  @_lifetime(&self)
  public mutating func fetchCursor<Value: ConvertibleFromOrbitDatabaseRow>(
    bindings: [OrbitDatabaseValue],
    as type: Value.Type
  ) throws -> OrbitDatabaseRowDecodingCursor<SQLiteRowCursor, Value> {
    try bindArguments(bindings)
    return OrbitDatabaseRowDecodingCursor(base: runCursor())
  }

  /// Runs the statement with the given arguments and returns a value made from each row.
  ///
  /// ```swift
  /// var titles = try transaction.prepare("SELECT title FROM reminders WHERE list_id = ?")
  /// for list in lists {
  ///   print(try titles.fetchAll(list.id) { $0[0].textValue ?? "" })
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - arguments: One value for each of the statement's parameters, in order.
  ///   - transform: Makes a value from a row. The row is only valid for the call.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever `transform` throws, a ``SQLiteError`` when the statement fails or the
  ///   arguments do not match ``parameterCount``, or whatever an argument throws converting to a
  ///   value.
  public mutating func fetchAll<each Argument: ConvertibleToOrbitDatabaseValue, Element>(
    _ arguments: repeat each Argument,
    transform: (inout SQLiteRow) throws -> Element
  ) throws -> [Element] {
    try bindArguments(repeat each arguments)
    return try withOrbitCursor(runCursor()) { try $0.collect(transform) }
  }

  /// Runs the statement with values gathered at runtime and returns a value made from each row.
  ///
  /// ```swift
  /// let titles = try titles.fetchAll(bindings: [.integer(listID)]) { $0[0].textValue ?? "" }
  /// ```
  ///
  /// - Parameters:
  ///   - bindings: One value for each of the statement's parameters, in order.
  ///   - transform: Makes a value from a row. The row is only valid for the call.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails or the
  ///   values do not match ``parameterCount``.
  public mutating func fetchAll<Element>(
    bindings: [OrbitDatabaseValue],
    _ transform: (inout SQLiteRow) throws -> Element
  ) throws -> [Element] {
    try bindArguments(bindings)
    return try withOrbitCursor(runCursor()) { try $0.collect(transform) }
  }

  /// Runs the statement with the given arguments and returns a value made from the first row, or
  /// `nil` when it returns none.
  ///
  /// Only the first row is read. SQLite makes every change a `RETURNING` statement reports on its
  /// first step, so the rows left unread are written all the same.
  ///
  /// ```swift
  /// var title = try transaction.prepare("SELECT title FROM reminders WHERE id = ?")
  /// let first = try title.fetchOne(id) { $0[0].textValue }
  /// ```
  ///
  /// - Parameters:
  ///   - arguments: One value for each of the statement's parameters, in order.
  ///   - transform: Makes a value from the row. The row is only valid for the call.
  /// - Returns: The value, or `nil` when the run returned no rows.
  /// - Throws: Whatever `transform` throws, a ``SQLiteError`` when the statement fails or the
  ///   arguments do not match ``parameterCount``, or whatever an argument throws converting to a
  ///   value.
  public mutating func fetchOne<each Argument: ConvertibleToOrbitDatabaseValue, Element>(
    _ arguments: repeat each Argument,
    transform: (inout SQLiteRow) throws -> Element
  ) throws -> Element? {
    try bindArguments(repeat each arguments)
    return try withOrbitCursor(runCursor()) { try $0.first(transform) }
  }

  /// Runs the statement with values gathered at runtime and returns a value made from the first
  /// row, or `nil` when it returns none.
  ///
  /// ```swift
  /// let first = try title.fetchOne(bindings: [.integer(id)]) { $0[0].textValue }
  /// ```
  ///
  /// - Parameters:
  ///   - bindings: One value for each of the statement's parameters, in order.
  ///   - transform: Makes a value from the row. The row is only valid for the call.
  /// - Returns: The value, or `nil` when the run returned no rows.
  /// - Throws: Whatever `transform` throws, or a ``SQLiteError`` when the statement fails or the
  ///   values do not match ``parameterCount``.
  public mutating func fetchOne<Element>(
    bindings: [OrbitDatabaseValue],
    _ transform: (inout SQLiteRow) throws -> Element
  ) throws -> Element? {
    try bindArguments(bindings)
    return try withOrbitCursor(runCursor()) { try $0.first(transform) }
  }
}

// The `as:` fetches, which convert rows as the transaction's do: a row-convertible type uses its
// row initializer, a type convertible only from a value reads the first column, and a type that
// is both uses its row initializer.
extension SQLitePreparedStatement {
  /// Runs the statement with the given arguments and returns the first column of each row,
  /// converted to a type.
  ///
  /// ```swift
  /// var ids = try transaction.prepare("SELECT id FROM reminders WHERE list_id = ?")
  /// let reminderIDs = try ids.fetchAll(listID, as: Int.self)
  /// ```
  ///
  /// - Parameters:
  ///   - arguments: One value for each of the statement's parameters, in order.
  ///   - type: The type to convert each value to. Make it optional to read `NULL`.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` when a value cannot be converted, or a
  ///   ``SQLiteError`` when the statement fails or the arguments do not match
  ///   ``parameterCount``.
  public mutating func fetchAll<
    each Argument: ConvertibleToOrbitDatabaseValue,
    Value: ConvertibleFromOrbitDatabaseValue
  >(
    _ arguments: repeat each Argument,
    as type: Value.Type
  ) throws -> [Value] {
    try fetchAll(repeat each arguments) { row in try row[0, as: Value.self] }
  }

  /// Runs the statement with the given arguments and initializes a value from each row.
  ///
  /// ```swift
  /// var byList = try transaction.prepare("SELECT * FROM reminders WHERE list_id = ?")
  /// let reminders = try byList.fetchAll(listID, as: Reminder.self)
  /// ```
  ///
  /// - Parameters:
  ///   - arguments: One value for each of the statement's parameters, in order.
  ///   - type: The type to initialize from each row.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever the type's row initializer throws, or a ``SQLiteError`` when the
  ///   statement fails or the arguments do not match ``parameterCount``.
  public mutating func fetchAll<
    each Argument: ConvertibleToOrbitDatabaseValue,
    Value: ConvertibleFromOrbitDatabaseRow
  >(
    _ arguments: repeat each Argument,
    as type: Value.Type
  ) throws -> [Value] {
    try fetchAll(repeat each arguments) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Uses row decoding for a type that also supports scalar conversion.
  ///
  /// ```swift
  /// let reminders = try byList.fetchAll(listID, as: Reminder.self)
  /// ```
  public mutating func fetchAll<
    each Argument: ConvertibleToOrbitDatabaseValue,
    Value: ConvertibleFromOrbitDatabaseRow & ConvertibleFromOrbitDatabaseValue
  >(
    _ arguments: repeat each Argument,
    as type: Value.Type
  ) throws -> [Value] {
    try fetchAll(repeat each arguments) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Runs the statement with the given arguments and returns the first column of the first row,
  /// converted to a type, or `nil` when it returns none.
  ///
  /// ```swift
  /// var count = try transaction.prepare("SELECT count(*) FROM reminders WHERE list_id = ?")
  /// let total = try count.fetchOne(listID, as: Int.self)
  /// ```
  ///
  /// - Parameters:
  ///   - arguments: One value for each of the statement's parameters, in order.
  ///   - type: The type to convert the value to.
  /// - Returns: The value, or `nil` when the run returned no rows.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` when the value cannot be converted, or a
  ///   ``SQLiteError`` when the statement fails or the arguments do not match
  ///   ``parameterCount``.
  public mutating func fetchOne<
    each Argument: ConvertibleToOrbitDatabaseValue,
    Value: ConvertibleFromOrbitDatabaseValue
  >(
    _ arguments: repeat each Argument,
    as type: Value.Type
  ) throws -> Value? {
    try fetchOne(repeat each arguments) { row in try row[0, as: Value.self] }
  }

  /// Runs the statement with the given arguments and initializes a value from the first row, or
  /// returns `nil` when it returns none.
  ///
  /// ```swift
  /// var byID = try transaction.prepare("SELECT * FROM reminders WHERE id = ?")
  /// let reminder = try byID.fetchOne(id, as: Reminder.self)
  /// ```
  ///
  /// - Parameters:
  ///   - arguments: One value for each of the statement's parameters, in order.
  ///   - type: The type to initialize from the row.
  /// - Returns: The value, or `nil` when the run returned no rows.
  /// - Throws: Whatever the type's row initializer throws, or a ``SQLiteError`` when the
  ///   statement fails or the arguments do not match ``parameterCount``.
  public mutating func fetchOne<
    each Argument: ConvertibleToOrbitDatabaseValue,
    Value: ConvertibleFromOrbitDatabaseRow
  >(
    _ arguments: repeat each Argument,
    as type: Value.Type
  ) throws -> Value? {
    try fetchOne(repeat each arguments) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Uses row decoding for a type that also supports scalar conversion.
  ///
  /// ```swift
  /// let reminder = try byID.fetchOne(id, as: Reminder.self)
  /// ```
  public mutating func fetchOne<
    each Argument: ConvertibleToOrbitDatabaseValue,
    Value: ConvertibleFromOrbitDatabaseRow & ConvertibleFromOrbitDatabaseValue
  >(
    _ arguments: repeat each Argument,
    as type: Value.Type
  ) throws -> Value? {
    try fetchOne(repeat each arguments) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Runs the statement with values gathered at runtime and returns the first column of each
  /// row, converted to a type.
  ///
  /// ```swift
  /// let reminderIDs = try ids.fetchAll(bindings: [.integer(listID)], as: Int.self)
  /// ```
  ///
  /// - Parameters:
  ///   - bindings: One value for each of the statement's parameters, in order.
  ///   - type: The type to convert each value to. Make it optional to read `NULL`.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` when a value cannot be converted, or a
  ///   ``SQLiteError`` when the statement fails or the values do not match ``parameterCount``.
  public mutating func fetchAll<Value: ConvertibleFromOrbitDatabaseValue>(
    bindings: [OrbitDatabaseValue],
    as type: Value.Type
  ) throws -> [Value] {
    try fetchAll(bindings: bindings) { row in try row[0, as: Value.self] }
  }

  /// Runs the statement with values gathered at runtime and initializes a value from each row.
  ///
  /// ```swift
  /// let reminders = try byList.fetchAll(bindings: [.integer(listID)], as: Reminder.self)
  /// ```
  ///
  /// - Parameters:
  ///   - bindings: One value for each of the statement's parameters, in order.
  ///   - type: The type to initialize from each row.
  /// - Returns: The values, in the order the rows were returned.
  /// - Throws: Whatever the type's row initializer throws, or a ``SQLiteError`` when the
  ///   statement fails or the values do not match ``parameterCount``.
  public mutating func fetchAll<Value: ConvertibleFromOrbitDatabaseRow>(
    bindings: [OrbitDatabaseValue],
    as type: Value.Type
  ) throws -> [Value] {
    try fetchAll(bindings: bindings) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Uses row decoding for a type that also supports scalar conversion.
  ///
  /// ```swift
  /// let reminders = try byList.fetchAll(bindings: [.integer(listID)], as: Reminder.self)
  /// ```
  public mutating func fetchAll<
    Value: ConvertibleFromOrbitDatabaseRow & ConvertibleFromOrbitDatabaseValue
  >(
    bindings: [OrbitDatabaseValue],
    as type: Value.Type
  ) throws -> [Value] {
    try fetchAll(bindings: bindings) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Runs the statement with values gathered at runtime and returns the first column of the
  /// first row, converted to a type, or `nil` when it returns none.
  ///
  /// ```swift
  /// let total = try count.fetchOne(bindings: [.integer(listID)], as: Int.self)
  /// ```
  ///
  /// - Parameters:
  ///   - bindings: One value for each of the statement's parameters, in order.
  ///   - type: The type to convert the value to.
  /// - Returns: The value, or `nil` when the run returned no rows.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` when the value cannot be converted, or a
  ///   ``SQLiteError`` when the statement fails or the values do not match ``parameterCount``.
  public mutating func fetchOne<Value: ConvertibleFromOrbitDatabaseValue>(
    bindings: [OrbitDatabaseValue],
    as type: Value.Type
  ) throws -> Value? {
    try fetchOne(bindings: bindings) { row in try row[0, as: Value.self] }
  }

  /// Runs the statement with values gathered at runtime and initializes a value from the first
  /// row, or returns `nil` when it returns none.
  ///
  /// ```swift
  /// let reminder = try byID.fetchOne(bindings: [.integer(id)], as: Reminder.self)
  /// ```
  ///
  /// - Parameters:
  ///   - bindings: One value for each of the statement's parameters, in order.
  ///   - type: The type to initialize from the row.
  /// - Returns: The value, or `nil` when the run returned no rows.
  /// - Throws: Whatever the type's row initializer throws, or a ``SQLiteError`` when the
  ///   statement fails or the values do not match ``parameterCount``.
  public mutating func fetchOne<Value: ConvertibleFromOrbitDatabaseRow>(
    bindings: [OrbitDatabaseValue],
    as type: Value.Type
  ) throws -> Value? {
    try fetchOne(bindings: bindings) { row in try Value(orbitDatabaseRow: row) }
  }

  /// Uses row decoding for a type that also supports scalar conversion.
  ///
  /// ```swift
  /// let reminder = try byID.fetchOne(bindings: [.integer(id)], as: Reminder.self)
  /// ```
  public mutating func fetchOne<
    Value: ConvertibleFromOrbitDatabaseRow & ConvertibleFromOrbitDatabaseValue
  >(
    bindings: [OrbitDatabaseValue],
    as type: Value.Type
  ) throws -> Value? {
    try fetchOne(bindings: bindings) { row in try Value(orbitDatabaseRow: row) }
  }
}

extension SQLitePreparedStatement where Access == OrbitDatabaseWriteAccess {
  /// Runs the statement with the given arguments to completion, discarding any rows it returns.
  ///
  /// Read the transaction's ``SQLiteWriteTransaction/changesCount`` afterwards for how many rows
  /// the run changed.
  ///
  /// ```swift
  /// var insert = try transaction.prepare("INSERT INTO items (a, b) VALUES (?, ?)")
  /// for item in items {
  ///   try insert.execute(item.a, item.b)
  /// }
  /// ```
  ///
  /// - Parameter arguments: One value for each of the statement's parameters, in order.
  /// - Throws: A ``SQLiteError`` when the statement fails or the arguments do not match
  ///   ``parameterCount``, or whatever an argument throws converting to a value.
  public mutating func execute<each Argument: ConvertibleToOrbitDatabaseValue>(
    _ arguments: repeat each Argument
  ) throws {
    try bindArguments(repeat each arguments)
    try withOrbitCursor(runCursor()) { cursor in
      while try cursor.next() != nil {}
    }
  }

  /// Runs the statement with values gathered at runtime to completion, discarding any rows it
  /// returns.
  ///
  /// ```swift
  /// try insert.execute(bindings: values.map { .integer($0) })
  /// ```
  ///
  /// - Parameter bindings: One value for each of the statement's parameters, in order.
  /// - Throws: A ``SQLiteError`` when the statement fails or the values do not match
  ///   ``parameterCount``.
  public mutating func execute(bindings: [OrbitDatabaseValue]) throws {
    try bindArguments(bindings)
    try withOrbitCursor(runCursor()) { cursor in
      while try cursor.next() != nil {}
    }
  }
}
