/// An error produced while deriving a database region from SQL.
public enum OrbitDatabaseRegionError: Error, Hashable, Sendable {
  /// The SQL compiled to a statement that may write.
  case writableStatement
}

extension OrbitDatabaseRegion {
  /// Creates the region read by raw SQL.
  ///
  /// SQLite compiles the SQL against the transaction's connection and reports every resolved
  /// table and column read. Read-only pragmas conservatively produce ``fullDatabase`` because
  /// SQLite does not report the schema state they inspect. The statement is never executed. Its
  /// bindings are not evaluated.
  ///
  /// ```swift
  /// let region = try await database.read { transaction in
  ///   try OrbitDatabaseRegion("SELECT title FROM reminders", in: transaction)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - sql: One read-only SQL statement.
  ///   - transaction: The transaction whose connection resolves the database schema.
  /// - Throws: ``OrbitDatabaseRegionError/writableStatement`` for a statement that may write,
  ///   or a ``SQLiteError`` when SQLite cannot compile the SQL.
  public init(
    _ sql: SQL,
    in transaction: borrowing SQLiteReadTransaction
  ) throws {
    self = try transaction.databaseRegion(readBy: sql)
  }
}

extension SQLiteReadTransaction {
  fileprivate borrowing func databaseRegion(readBy query: SQL) throws
    -> OrbitDatabaseRegion
  {
    let (statement, authorizations) = try authorizer.recordingAuthorizations {
      try library.pointee.prepareStatement(query.text, on: connection)
    }
    guard let statement else { return .empty }
    defer { _ = library.pointee.statements.execution.finalize(statement) }

    guard library.pointee.statements.inspection.isReadOnly(statement) != 0 else {
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
  readBy authorizations: [SQLiteRawAuthorization],
  resolvingSchema: (String) -> SQLiteSchemaName?
) -> OrbitDatabaseRegion {
  // A successfully compiled statement normally produces at least one authorization, even when it
  // reads no database values. No authorizations means SQLite's single callback was displaced or
  // unavailable, so an empty region would be unsafe.
  guard !authorizations.isEmpty else { return .fullDatabase }

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
  let query: SQL = "SELECT * FROM \(quote: table) LIMIT 0"
  guard
    let prepared = try? authorizer.recordingAuthorizations(during: {
      try library.pointee.prepare(query.text, on: connection)
    }),
    let statement = prepared.result
  else { return nil }
  defer { _ = library.pointee.statements.execution.finalize(statement) }

  let normalizedTable = table.asciiLowercased
  return prepared.authorizations.first {
    $0.sourceName == nil && $0.firstArgument?.asciiLowercased == normalizedTable
  }?
  .schemaName.map(SQLiteSchemaName.init(rawValue:))
}
