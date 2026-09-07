import StructuredQueries

/// An error produced while deriving a database region from SQL.
public enum OrbitDatabaseRegionError: Error, Hashable, Sendable {
  /// The query fragment compiled to a statement that may write.
  case writableStatement
}

extension OrbitDatabaseRegion {
  /// Creates the region read by a query fragment.
  ///
  /// SQLite compiles the fragment against the transaction's connection and reports every resolved
  /// table and column read. Read-only pragmas conservatively produce ``fullDatabase`` because
  /// SQLite does not report the schema state they inspect. The statement is never executed. Its
  /// bindings are not evaluated.
  ///
  /// ```swift
  /// let region = try await database.read { transaction in
  ///   try OrbitDatabaseRegion(
  ///     #sql("SELECT title FROM reminders", as: String.self).query,
  ///     in: transaction
  ///   )
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - query: A fragment containing one read-only SQL statement.
  ///   - transaction: The transaction whose connection resolves the database schema.
  /// - Throws: ``OrbitDatabaseRegionError/writableStatement`` for a statement that may write,
  ///   or a ``SQLiteError`` when SQLite cannot compile the fragment.
  public init(
    _ query: QueryFragment,
    in transaction: borrowing SQLiteReadTransaction
  ) throws {
    self = try transaction.databaseRegion(readBy: query)
  }
}

extension SQLiteReadTransaction {
  fileprivate borrowing func databaseRegion(readBy query: QueryFragment) throws
    -> OrbitDatabaseRegion
  {
    let (statement, authorizations) = try sqlitePrepare(
      query,
      on: connection,
      library: library,
      authorizer: authorizer
    )
    guard let statement else { return .empty }
    defer { _ = library.pointee.finalize(statement) }

    guard library.pointee.stmt_readonly(statement) != 0 else {
      throw OrbitDatabaseRegionError.writableStatement
    }

    return sqliteDatabaseRegion(readBy: authorizations) { table in
      sqliteResolvedSchema(
        for: table,
        on: connection,
        library: library,
        authorizer: authorizer
      )
    }
  }
}

func sqliteDatabaseRegion(
  readBy authorizations: [SQLiteAuthorization],
  resolvingSchema: (String) -> SQLiteSchemaName?
) -> OrbitDatabaseRegion {
  var region = OrbitDatabaseRegion.empty
  for authorization in authorizations {
    // SQLite reports pragma access without the tables or schema state it may inspect.
    if authorization.action == .pragma { return .fullDatabase }
    guard authorization.action == .read else { continue }
    guard let table = authorization.firstArgument else { return .fullDatabase }
    guard
      let schema =
        authorization.schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? resolvingSchema(table)
    else {
      return .fullDatabase
    }

    if let column = authorization.secondArgument, !column.isEmpty {
      region.formUnion(OrbitDatabaseRegion(column: column, in: table, schema: schema))
    } else {
      region.formUnion(OrbitDatabaseRegion(table: table, schema: schema))
    }
  }
  return region
}

func sqliteResolvedSchema(
  for table: String,
  on connection: OpaquePointer,
  library: UnsafePointer<SQLiteLibrary>,
  authorizer: SQLiteAuthorizerDispatcher
) -> SQLiteSchemaName? {
  let query: QueryFragment = "SELECT * FROM \(quote: table) LIMIT 0"
  guard
    let prepared = try? sqlitePrepare(
      query,
      on: connection,
      library: library,
      authorizer: authorizer
    ),
    let statement = prepared.statement
  else { return nil }
  defer { _ = library.pointee.finalize(statement) }

  let normalizedTable = table.asciiLowercased
  return prepared.authorizations.first {
    $0.sourceName == nil && $0.firstArgument?.asciiLowercased == normalizedTable
  }?
  .schemaName.map(SQLiteSchemaName.init(rawValue:))
}

private func sqlitePrepare(
  _ query: QueryFragment,
  on connection: OpaquePointer,
  library: UnsafePointer<SQLiteLibrary>,
  authorizer: SQLiteAuthorizerDispatcher
) throws -> (statement: OpaquePointer?, authorizations: [SQLiteAuthorization]) {
  let (sql, _) = query.prepare { _ in "?" }
  var statement: OpaquePointer?
  let (code, authorizations) = authorizer.recordingAuthorizations {
    sql.withCString {
      library.pointee.prepare_v3(connection, $0, -1, 0, &statement, nil)
    }
  }
  guard code == SQLiteResultCode.ok.rawValue else {
    if let statement { _ = library.pointee.finalize(statement) }
    throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
  }
  return (statement, authorizations)
}
