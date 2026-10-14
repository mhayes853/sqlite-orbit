/// A cursor over the rows a statement produces.
///
/// The cursor holds a statement lent by the connection's cache and gives it back when it goes out
/// of scope. That is only safe because the cursor is nonescapable: it cannot outlive the
/// transaction that created it, so a cached statement can never be lent twice or survive its
/// connection. A cursor over a run of a ``SQLitePreparedStatement`` holds that statement instead,
/// and only resets it when it goes out of scope, so the statement is ready to run again.
///
/// This is the ``OrbitDatabaseRowCursor`` the native drivers lend; it is created by
/// ``OrbitDatabaseReadTransaction/rowCursor(_:cached:)`` rather than directly.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor: SQLiteRowCursor = try transaction.rowCursor("SELECT title FROM reminders")
///   try cursor.forEach { print($0[0].textValue ?? "") }
/// }
/// ```
public struct SQLiteRowCursor: OrbitDatabaseRowCursor, ~Copyable, ~Escapable {
  /// The row this cursor lends.
  public typealias Row = SQLiteRow

  let library: UnsafePointer<SQLiteLibrary>

  let connection: OpaquePointer

  let sql: String

  let statements: SQLiteStatementCache

  // What a statement lent by the cache is given back under, or `nil` for one the cache did not
  // lend.
  let loan: SQLiteStatementLoan?

  // The prepared statement whose statement this cursor runs, or `nil` for any other cursor. With
  // neither a loan nor a prepared statement, the statement was compiled for this cursor alone and
  // is finalized with it. Metadata the cursor refreshes on its first step is recorded in the
  // prepared statement's state, where the next run finds it.
  let prepared: SQLitePreparedStatementState?

  // The prepared statement's run this cursor is over. The cursor only resets the statement while
  // this is still the latest run.
  let preparedRun: UInt64

  // What SQLite steps, or `nil` for SQL that holds no statement, such as an empty query, which
  // produces no rows. A statement recompiled on its first step keeps its pointer and has only its
  // metadata replaced.
  var compiledStatement: SQLiteCompiledStatement?

  let authorizer: SQLiteAuthorizerDispatcher
  let authorizationGeneration: UInt64
  let connectionState: SQLiteConnectionState?

  let observations: SQLiteConnectionEvents

  var isExhausted = false

  var didPublishAccesses = false

  // Made with the first row, so a statement that returns none, such as most writes, never needs
  // one.
  var columnReader: SQLiteRowColumnReader?

  // Read once the statement has produced a row, when SQLite can no longer recompile it, so every
  // row shares it instead of asking SQLite again for each value read.
  var columnCount: Int32 = -1

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
    let (compiledStatement, loan, sql) = try statements.statement(
      for: query,
      cached: cached,
      requiresReadOnly: requiresReadOnly
    )
    if let compiledStatement {
      do {
        try bind(query, to: compiledStatement.pointer, library: library)
      } catch {
        // The statement never reached a cursor, so nothing else will give it back.
        statements.giveBack(compiledStatement, loan: loan)
        throw error
      }
    }
    self.library = library
    self.connection = connection
    self.sql = sql
    self.statements = copy statements
    self.loan = loan
    self.prepared = nil
    self.preparedRun = 0
    self.compiledStatement = compiledStatement
    self.authorizer = authorizer
    self.authorizationGeneration = authorizer.generation
    self.connectionState = connectionState
    self.observations = observations
    if compiledStatement != nil { authorizer.activeCursors += 1 }
  }

  // A run of a prepared statement, whose values are already bound. The authorization generation
  // is the one the statement was prepared under, so a run on the far side of an authorization
  // scope boundary is refused just as a cursor carried across one is.
  @_lifetime(borrow statements)
  init(
    running state: SQLitePreparedStatementState?,
    sql: String,
    authorizationGeneration: UInt64,
    connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    statements: borrowing SQLiteStatementCache,
    authorizer: SQLiteAuthorizerDispatcher,
    observations: SQLiteConnectionEvents,
    connectionState: SQLiteConnectionState?
  ) {
    self.library = library
    self.connection = connection
    self.sql = sql
    self.statements = copy statements
    self.loan = nil
    self.prepared = state
    self.preparedRun = state?.run ?? 0
    self.compiledStatement = state?.statement
    self.authorizer = authorizer
    self.authorizationGeneration = authorizationGeneration
    self.connectionState = connectionState
    self.observations = observations
    if compiledStatement != nil { authorizer.activeCursors += 1 }
  }

  // Inlined where cursors end. Called instead, it keeps the statement cache's check-in from being
  // optimized together with the check-out, which costs every cached run of `execute` about 300
  // instructions.
  @inline(__always)
  deinit {
    guard let compiledStatement else { return }
    authorizer.activeCursors -= 1
    if let loan {
      statements.checkIn(compiledStatement, loan: loan)
    } else if let prepared {
      prepared.finishRun(preparedRun, library: library)
    } else {
      _ = library.pointee.statements.execution.finalize(compiledStatement.pointer)
    }
  }

  /// Steps the statement and lends the row it produced, or returns `nil` once it is done.
  ///
  /// The returned row is only valid until the cursor advances again. A statement that fails
  /// leaves the cursor exhausted, so the failure is reported once.
  ///
  /// - Returns: The next row, or `nil` when the statement has no more.
  /// - Throws: A ``SQLiteError`` carrying the code the statement failed with.
  @_lifetime(&self)
  public mutating func next() throws -> SQLiteRow? {
    guard !isExhausted, let statement = compiledStatement?.pointer else { return nil }
    guard authorizationGeneration == authorizer.generation else {
      isExhausted = true
      throw SQLiteError(
        code: .misuse,
        message: "A cursor cannot cross an authorization scope boundary",
        sql: sql
      )
    }
    // Preparation-time authorization does not run again when a cached statement is reused.
    // Consult the live scope here, before any SQL executes or observations are published.
    if compiledStatement?.controlsTransactions == true,
      connectionState?.isInTransaction == false
    {
      isExhausted = true
      throw SQLiteError(
        code: .auth,
        message: "Transaction control requires connection.transaction",
        sql: sql
      )
    }
    if !didPublishAccesses {
      didPublishAccesses = true
      // SQLite may recompile a cached statement on its first step after another connection changed
      // the schema. Its callbacks cover both the retired and replacement programs, so prepare a
      // fresh copy to capture only the replacement's metadata. Falling back to their union is safe.
      let (code, authorizations) = authorizer.recordingAuthorizations {
        library.pointee.statements.execution.step(statement)
      }
      if !authorizations.isEmpty {
        statements.invalidate()
        refreshMetadata(
          statements.refreshedMetadata(for: statement, sql: sql)
            ?? SQLiteCompiledStatement(
              pointer: statement,
              isReadOnly: library.pointee.statements.inspection.isReadOnly(statement) != 0,
              authorizations: authorizations,
              cacheGeneration: statements.generation,
              statements: statements,
              connection: connection,
              authorizer: authorizer,
              library: library
            )
        )
      } else if prepared != nil {
        refreshMetadataIfSchemaChanged(of: statement)
      }
      publishAccesses()
      return try row(for: code, of: statement)
    }
    return try row(for: library.pointee.statements.execution.step(statement), of: statement)
  }

  private mutating func refreshMetadata(_ refreshed: SQLiteCompiledStatement) {
    compiledStatement = refreshed
    prepared?.statement = refreshed
  }

  // A prepared statement run again after the schema changed, by DDL earlier in its transaction,
  // that SQLite did not need to recompile, was compiled with regions that may describe a schema
  // that is gone. A cursor over a cached statement never gets here: the cache empties itself when
  // the schema changes, so it only lends statements compiled under the current one.
  @inline(never)
  private mutating func refreshMetadataIfSchemaChanged(of statement: OpaquePointer) {
    guard
      compiledStatement?.cacheGeneration != statements.generation,
      let refreshed = statements.refreshedMetadata(for: statement, sql: sql)
    else { return }
    refreshMetadata(refreshed)
  }

  private mutating func publishAccesses() {
    guard let compiledStatement else { return }
    observations.didRead(in: compiledStatement.readRegion)
    observations.didChange(in: compiledStatement.changedRegion)
    if compiledStatement.invalidatesStatementCache {
      statements.invalidate()
    }
  }

  @_lifetime(&self)
  private mutating func row(for code: Int32, of statement: OpaquePointer) throws -> SQLiteRow? {
    switch code {
    case SQLiteResultCode.row.rawValue:
      if columnReader == nil {
        columnReader = SQLiteRowColumnReader(columns: library.pointee.columns)
        columnCount = library.pointee.columns.count(statement)
      }
      return SQLiteRow(cursor: self, statement: statement)
    case SQLiteResultCode.done.rawValue:
      isExhausted = true
      return nil
    default:
      isExhausted = true
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
    }
  }
}

/// One result row, valid only until its cursor advances.
///
/// Read a column by its position or by its name. Reading a column this way does not disturb the
/// Structured Queries decoder, which walks the row from left to right on its own.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.rowCursor("SELECT id, title FROM reminders")
///   while var row: SQLiteRow = try cursor.next() {
///     print(row[0].integerValue ?? 0, row[column: "title"]?.textValue ?? "")
///   }
/// }
/// ```
public struct SQLiteRow: OrbitDatabaseRow, ~Copyable, ~Escapable {
  /// How many columns the row has.
  public let columnCount: Int

  @usableFromInline
  let library: UnsafePointer<SQLiteLibrary>

  @usableFromInline
  let statement: OpaquePointer

  // Held without a reference count, which leaves the row nothing to release, so making and
  // discarding one costs no more than copying its fields. That is safe because the cursor holds
  // the reader strongly from its first row on and never replaces it, and a row cannot outlive the
  // cursor that lent it.
  @usableFromInline
  let columnReader: Unmanaged<SQLiteRowColumnReader>

  #if StructuredQueries
    // The column the Structured Queries decoder reads next. Each decode builds its decoder from
    // the fields above and this position, and writes the position back.
    @usableFromInline
    var decodeIndex: Int32 = 0
  #endif

  @usableFromInline
  @_lifetime(borrow cursor)
  init(cursor: borrowing SQLiteRowCursor, statement: OpaquePointer) {
    self.library = cursor.library
    self.statement = statement
    self.columnReader = .passUnretained(cursor.columnReader!)
    self.columnCount = Int(cursor.columnCount)
  }

  /// The name of a column, as SQLite reports it.
  ///
  /// - Parameter index: The column's zero-based position, which must be less than
  ///   ``columnCount``.
  /// - Returns: The column's name, or an empty string when SQLite has none for it.
  public func columnName(at index: Int) -> String {
    precondition(index: index)
    return library.pointee.columns.name(statement, Int32(index)).map(String.init(cString:)) ?? ""
  }

  /// The value of a column, in the storage class SQLite holds it in.
  ///
  /// - Parameter index: The column's zero-based position. A position outside the row stops the
  ///   process.
  @inlinable
  @inline(__always)
  public subscript(index: Int) -> OrbitDatabaseValue {
    precondition(index: index)
    // Each value is read in the storage class SQLite reports, so reading it never converts it, and
    // a later decode of the same column sees what it would have seen anyway.
    return columnReader._withUnsafeGuaranteedRef { $0.value(statement, at: Int32(index)) }
  }

  /// Finds a column by its exact UTF-8 name using a mapping shared by this cursor's rows.
  public func columnIndex(named name: String) -> Int? {
    columnReader._withUnsafeGuaranteedRef { $0.index(named: name, statement: statement) }
  }

  @inlinable
  func precondition(index: Int) {
    Swift.precondition(
      index >= 0 && index < columnCount,
      "Column index \(index) is out of range for a row of \(columnCount) columns"
    )
  }
}
