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
  /// table and column read. The statement is never executed. Its bindings are not evaluated.
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
    let (statement, reads) = try prepare(query)
    guard let statement else { return .empty }
    defer { _ = library.pointee.finalize(statement) }

    guard library.pointee.stmt_readonly(statement) != 0 else {
      throw OrbitDatabaseRegionError.writableStatement
    }

    var region = OrbitDatabaseRegion.empty
    for read in reads {
      guard let table = read.firstArgument else {
        return .fullDatabase
      }
      guard
        let schema =
          read.schemaName.map(SQLiteSchemaName.init(rawValue:)) ?? resolvedSchema(for: table)
      else {
        // SQLite normally omits the schema only for an unqualified `count(*)`. If an unusual
        // virtual table or extension prevents resolving it, observe conservatively.
        return .fullDatabase
      }

      if let column = read.secondArgument, !column.isEmpty {
        region.formUnion(OrbitDatabaseRegion(column: column, in: table, schema: schema))
      } else {
        region.formUnion(OrbitDatabaseRegion(table: table, schema: schema))
      }
    }
    return region
  }

  private borrowing func prepare(_ query: QueryFragment) throws -> (
    statement: OpaquePointer?, reads: [SQLiteAuthorization]
  ) {
    let (sql, _) = query.prepare { _ in "?" }
    var reads: [SQLiteAuthorization] = []
    var statement: OpaquePointer?
    let code = authorizer.withHandler(
      { authorization in
        // SQLITE_READ is part of SQLite's stable ABI.
        if authorization.actionCode == 20 {
          reads.append(authorization)
        }
        return .allow
      },
      perform: {
        sql.withCString {
          library.pointee.prepare_v3(connection, $0, -1, 0, &statement, nil)
        }
      }
    )
    guard code == SQLiteResultCode.ok.rawValue else {
      if let statement {
        _ = library.pointee.finalize(statement)
      }
      throw SQLiteError.reported(
        by: library.pointee,
        on: connection,
        code: code,
        sql: sql
      )
    }
    return (statement, reads)
  }

  private borrowing func resolvedSchema(for table: String) -> SQLiteSchemaName? {
    let query: QueryFragment = "SELECT * FROM \(quote: table) LIMIT 0"
    guard let prepared = try? prepare(query), let statement = prepared.statement else { return nil }
    defer { _ = library.pointee.finalize(statement) }

    let normalizedTable = table.asciiLowercased
    return prepared.reads.first {
      $0.sourceName == nil && $0.firstArgument?.asciiLowercased == normalizedTable
    }?
    .schemaName.map(SQLiteSchemaName.init(rawValue:))
  }
}
