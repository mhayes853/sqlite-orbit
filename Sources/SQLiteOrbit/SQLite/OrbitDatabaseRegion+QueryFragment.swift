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
    let collector = SQLiteReadAuthorizationCollector()
    let (sql, _) = query.prepare { _ in "?" }
    let statement = try prepare(sql, collectingWith: collector)
    guard let statement else { return .empty }
    defer { _ = library.pointee.finalize(statement) }

    guard library.pointee.stmt_readonly(statement) != 0 else {
      throw OrbitDatabaseRegionError.writableStatement
    }

    var region = OrbitDatabaseRegion.empty
    for read in collector.reads {
      guard let table = read.tableName else {
        return .fullDatabase
      }
      let schema: SQLiteSchemaName
      if let schemaName = read.schemaName {
        schema = SQLiteSchemaName(schemaName)
      } else if let resolvedSchema = resolvedSchema(for: table) {
        schema = resolvedSchema
      } else {
        // SQLite normally omits the schema only for an unqualified `count(*)`. If an unusual
        // virtual table or extension prevents resolving it, observe conservatively.
        return .fullDatabase
      }

      if let column = read.columnName, !column.isEmpty {
        region.formUnion(OrbitDatabaseRegion(column: column, in: table, schema: schema))
      } else {
        region.formUnion(OrbitDatabaseRegion(table: table, schema: schema))
      }
    }
    return region
  }

  private borrowing func prepare(
    _ sql: String,
    collectingWith collector: SQLiteReadAuthorizationCollector
  ) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    let code = authorizer.withHandler(collector.authorize) {
      sql.withCString {
        library.pointee.prepare_v3(connection, $0, -1, 0, &statement, nil)
      }
    }
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
    return statement
  }

  private borrowing func resolvedSchema(for table: String) -> SQLiteSchemaName? {
    let collector = SQLiteReadAuthorizationCollector()
    let query: QueryFragment = "SELECT * FROM \(quote: table) LIMIT 0"
    let (sql, _) = query.prepare { _ in "?" }
    let statement: OpaquePointer?
    do {
      statement = try prepare(sql, collectingWith: collector)
    } catch {
      return nil
    }
    guard let statement else { return nil }
    defer { _ = library.pointee.finalize(statement) }

    let normalizedTable = table.asciiLowercased
    for read in collector.reads
    where read.sourceName == nil && read.tableName?.asciiLowercased == normalizedTable {
      if let schemaName = read.schemaName {
        return SQLiteSchemaName(schemaName)
      }
    }
    return nil
  }
}

private final class SQLiteReadAuthorizationCollector {
  struct Read {
    let tableName: String?
    let columnName: String?
    let schemaName: String?
    let sourceName: String?
  }

  var reads: [Read] = []

  func authorize(_ authorization: SQLiteAuthorization) -> SQLiteAuthorizationDecision {
    // SQLITE_READ is part of SQLite's stable ABI.
    guard authorization.actionCode == 20 else { return .allow }
    reads.append(
      Read(
        tableName: authorization.firstArgument,
        columnName: authorization.secondArgument,
        schemaName: authorization.schemaName,
        sourceName: authorization.sourceName
      )
    )
    return .allow
  }
}
