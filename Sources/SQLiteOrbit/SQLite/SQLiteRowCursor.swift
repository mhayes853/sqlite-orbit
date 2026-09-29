/// A cursor over the rows a statement produces.
///
/// The cursor holds a statement lent by the connection's cache and gives it back when it goes out
/// of scope. That is only safe because the cursor is nonescapable: it cannot outlive the
/// transaction that created it, so a cached statement can never be lent twice or survive its
/// connection.
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

  let isCached: Bool

  var preparedStatement: SQLitePreparedStatement

  // What SQLite steps. A statement recompiled on its first step keeps its pointer and has only
  // its metadata replaced.
  var statement: OpaquePointer { preparedStatement.pointer }

  let authorizer: SQLiteAuthorizerDispatcher

  let observations: OrbitDatabaseTransactionObservationContext

  var isExhausted = false

  var didPublishAccesses = false

  @_lifetime(borrow statements)
  init(
    _ query: SQL,
    cached: Bool,
    requiresReadOnly: Bool,
    connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    statements: borrowing SQLiteStatementCache,
    authorizer: SQLiteAuthorizerDispatcher,
    observations: OrbitDatabaseTransactionObservationContext
  ) throws {
    let sql = query.preparedText
    let preparedStatement = cached ? try statements.checkOut(sql) : try statements.prepare(sql)
    let statement = preparedStatement.pointer
    do {
      // Raw SQL cannot show through its type that it only reads, so a read query is held to it
      // here, before anything has run.
      if requiresReadOnly && !preparedStatement.isReadOnly {
        throw SQLiteError(
          code: .readOnly,
          message: "a read-only query may write; run it in a write transaction instead",
          sql: sql
        )
      }
      try bind(query, to: statement, library: library)
    } catch {
      // The statement never reached a cursor, so nothing else will give it back.
      if cached {
        statements.checkIn(preparedStatement, sql: sql)
      } else {
        _ = library.pointee.statements.execution.finalize(statement)
      }
      throw error
    }
    self.library = library
    self.connection = connection
    self.sql = sql
    self.statements = copy statements
    self.isCached = cached
    self.preparedStatement = preparedStatement
    self.authorizer = authorizer
    self.observations = observations
  }

  deinit {
    if isCached {
      statements.checkIn(preparedStatement, sql: sql)
    } else {
      _ = library.pointee.statements.execution.finalize(statement)
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
    guard !isExhausted else { return nil }
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
        preparedStatement =
          statements.refreshedMetadata(for: statement, sql: sql)
          ?? SQLitePreparedStatement(
            pointer: statement,
            authorizations: authorizations,
            cacheGeneration: statements.generation,
            statements: statements,
            connection: connection,
            authorizer: authorizer,
            library: library
          )
      }
      publishAccesses()
      return try row(for: code)
    }
    return try row(for: library.pointee.statements.execution.step(statement))
  }

  private mutating func publishAccesses() {
    observations.didRead(in: preparedStatement.readRegion)
    observations.didChange(in: preparedStatement.changedRegion)
    if preparedStatement.invalidatesStatementCache {
      statements.invalidate()
    }
  }

  @_lifetime(&self)
  private mutating func row(for code: Int32) throws -> SQLiteRow? {
    switch code {
    case SQLiteResultCode.row.rawValue:
      return SQLiteRow(cursor: self)
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
  #if StructuredQueries
    @usableFromInline
    var decoder: SQLiteRowDecoder

    @usableFromInline
    var library: UnsafePointer<SQLiteLibrary> { decoder.library }

    @usableFromInline
    var statement: OpaquePointer { decoder.statement }

    @usableFromInline
    @_lifetime(borrow cursor)
    init(cursor: borrowing SQLiteRowCursor) {
      self.decoder = SQLiteRowDecoder(library: cursor.library, statement: cursor.statement)
    }
  #else
    @usableFromInline
    let library: UnsafePointer<SQLiteLibrary>

    @usableFromInline
    let statement: OpaquePointer

    @usableFromInline
    @_lifetime(borrow cursor)
    init(cursor: borrowing SQLiteRowCursor) {
      self.library = cursor.library
      self.statement = cursor.statement
    }
  #endif

  /// How many columns the row has.
  public var columnCount: Int {
    Int(library.pointee.columns.count(statement))
  }

  /// The name of a column, as SQLite reports it.
  ///
  /// - Parameter index: The column's zero-based position, which must be less than
  ///   ``columnCount``.
  /// - Returns: The column's name, or an empty string when SQLite has none for it.
  public func columnName(at index: Int) -> String {
    precondition(
      index >= 0 && index < columnCount,
      "Column index \(index) is out of range for a row of \(columnCount) columns"
    )
    return library.pointee.columns.name(statement, Int32(index)).map(String.init(cString:)) ?? ""
  }

  /// The value of a column, in the storage class SQLite holds it in.
  ///
  /// - Parameter index: The column's zero-based position. A position outside the row stops the
  ///   process.
  public subscript(index: Int) -> OrbitDatabaseValue {
    precondition(
      index >= 0 && index < columnCount,
      "Column index \(index) is out of range for a row of \(columnCount) columns"
    )
    let column = Int32(index)
    // Each value is read in the storage class SQLite reports, so reading it never converts it, and
    // a later decode of the same column sees what it would have seen anyway.
    switch SQLiteColumnType(rawValue: library.pointee.columns.type(statement, column)) {
    case .integer:
      return .integer(library.pointee.columns.int64(statement, column))
    case .float:
      return .real(library.pointee.columns.double(statement, column))
    case .text:
      // The value is read before its size, which is the order SQLite documents as safe.
      guard let text = library.pointee.columns.text(statement, column) else { return .text("") }
      let byteCount = Int(library.pointee.columns.byteCount(statement, column))
      return .text(
        String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self)
      )
    case .blob:
      guard let bytes = library.pointee.columns.blob(statement, column) else { return .blob([]) }
      let byteCount = Int(library.pointee.columns.byteCount(statement, column))
      return .blob([UInt8](UnsafeRawBufferPointer(start: bytes, count: byteCount)))
    default:
      return .null
    }
  }
}
