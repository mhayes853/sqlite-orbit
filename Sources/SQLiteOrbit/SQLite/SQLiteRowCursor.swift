import StructuredQueries

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
///   var cursor: SQLiteRowCursor = try transaction.rowCursor(Reminder.select(\.title))
///   try cursor.forEach { print(try $0.decode(String.self)) }
/// }
/// ```
public struct SQLiteRowCursor: OrbitDatabaseRowCursor, ~Copyable, ~Escapable {
  /// The row this cursor lends.
  public typealias Row = SQLiteRow

  @usableFromInline
  let library: UnsafePointer<SQLiteLibrary>

  @usableFromInline
  let statement: OpaquePointer

  @usableFromInline
  let connection: OpaquePointer

  @usableFromInline
  let sql: String

  let statements: SQLiteStatementCache

  let isCached: Bool

  var preparedStatement: SQLitePreparedStatement

  let authorizer: SQLiteAuthorizerDispatcher

  let observations: OrbitDatabaseTransactionObservationContext

  @usableFromInline
  var isExhausted = false

  var didPublishAccesses = false

  @_lifetime(borrow statements)
  init(
    _ query: QueryFragment,
    cached: Bool,
    connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    statements: borrowing SQLiteStatementCache,
    authorizer: SQLiteAuthorizerDispatcher,
    observations: OrbitDatabaseTransactionObservationContext
  ) throws {
    let (sql, bindings) = prepareQuery(query)
    let preparedStatement = cached ? try statements.checkOut(sql) : try statements.prepare(sql)
    let statement = preparedStatement.pointer
    do {
      for (offset, binding) in bindings.enumerated() {
        try bind(binding, to: statement, at: Int32(offset + 1), library: library)
      }
    } catch {
      // The statement never reached a cursor, so nothing else will give it back.
      if cached {
        statements.checkIn(preparedStatement, sql: sql)
      } else {
        _ = library.pointee.finalize(statement)
      }
      throw error
    }
    self.library = library
    self.statement = statement
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
      _ = library.pointee.finalize(statement)
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
        library.pointee.step(statement)
      }
      if !authorizations.isEmpty {
        statements.invalidate()
        preparedStatement =
          statements.refreshedMetadata(for: statement, sql: sql)
          ?? SQLitePreparedStatement(
            pointer: statement,
            authorizations: authorizations,
            cacheGeneration: statements.currentGeneration,
            statements: statements,
            connection: connection,
            authorizer: authorizer,
            library: library
          )
      }
      publishAccesses()
      return try row(for: code)
    }
    return try row(for: library.pointee.step(statement))
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
/// Each `decode` reads the next column of the row, so decoding a row's columns is a walk from
/// left to right rather than a set of random accesses.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.rowCursor(
///     #sql("SELECT id, title FROM reminders", as: Void.self)
///   )
///   while var row: SQLiteRow = try cursor.next() {
///     print(try row.decode(Int.self), try row.decode(String.self))
///   }
/// }
/// ```
public struct SQLiteRow: OrbitDatabaseRow, ~Copyable, ~Escapable {
  @usableFromInline
  var decoder: SQLiteRowDecoder

  @usableFromInline
  @_lifetime(borrow cursor)
  init(cursor: borrowing SQLiteRowCursor) {
    self.decoder = SQLiteRowDecoder(library: cursor.library, statement: cursor.statement)
  }

  /// Decodes the next column of this row.
  ///
  /// - Parameter type: The value to decode.
  /// - Returns: The decoded value.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` naming the column when its storage class or
  ///   contents cannot produce `type`.
  @inlinable
  public mutating func decode<Value: QueryRepresentable>(
    _ type: Value.Type
  ) throws -> Value.QueryOutput {
    do {
      return try Value(decoder: &decoder).queryOutput
    } catch let error as QueryDecodingError {
      throw decoder.describe(error)
    }
  }

  /// Decodes the next columns of this row as a tuple, one column per value.
  ///
  /// - Parameter type: The tuple of values to decode.
  /// - Returns: The decoded values.
  /// - Throws: ``OrbitDatabaseColumnDecodingError`` naming the column that could not be decoded.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @inlinable
  public mutating func decode<each Value: QueryRepresentable>(
    _ type: (repeat each Value).Type
  ) throws -> (repeat (each Value).QueryOutput) {
    do {
      return try decoder.decodeColumns((repeat each Value).self)
    } catch let error as QueryDecodingError {
      throw decoder.describe(error)
    }
  }
}
