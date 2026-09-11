import StructuredQueries

/// One row whose foreign key refers to a row that does not exist, as `PRAGMA foreign_key_check`
/// reports it.
///
/// With foreign keys off, SQLite lets a statement leave such a row behind, which is what a table
/// rebuild relies on while the old table is gone. Checking afterwards is how the rebuild confirms
/// that it left nothing dangling.
///
/// ```swift
/// try await database.writeWithoutTransaction { connection in
///   connection.isForeignKeysEnabled = false
///   try connection.transaction { transaction in
///     try rebuildLists(in: transaction)
///     let violations = try transaction.foreignKeyViolations()
///     guard violations.isEmpty else { throw RebuildError(violations: violations) }
///   }
/// }
/// ```
public struct OrbitDatabaseForeignKeyViolation: Hashable, Sendable {
  /// The table holding the row with the dangling reference.
  public let table: String

  /// The row's rowid, or `nil` for a row of a `WITHOUT ROWID` table.
  public let rowID: Int64?

  /// The table the row's foreign key refers to.
  public let parentTable: String

  /// Which of the table's foreign keys is violated, numbered as `PRAGMA foreign_key_list` numbers
  /// them.
  public let foreignKeyIndex: Int

  /// Creates a violation.
  ///
  /// ```swift
  /// let expected = OrbitDatabaseForeignKeyViolation(
  ///   table: "reminders",
  ///   rowID: 3,
  ///   parentTable: "lists",
  ///   foreignKeyIndex: 0
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - table: The table holding the row with the dangling reference.
  ///   - rowID: The row's rowid, or `nil` for a row of a `WITHOUT ROWID` table.
  ///   - parentTable: The table the row's foreign key refers to.
  ///   - foreignKeyIndex: Which of the table's foreign keys is violated.
  public init(table: String, rowID: Int64?, parentTable: String, foreignKeyIndex: Int) {
    self.table = table
    self.rowID = rowID
    self.parentTable = parentTable
    self.foreignKeyIndex = foreignKeyIndex
  }
}

extension SQLiteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Returns every row in the database whose foreign key refers to a row that does not exist.
  ///
  /// This runs `PRAGMA foreign_key_check`, which reads every table that has a foreign key, so it
  /// can take a while on a large database. It finds violations whether or not foreign keys are
  /// enforced, which is what makes it the check to run after changes made with them off.
  ///
  /// ```swift
  /// let violations = try await database.read { try $0.foreignKeyViolations() }
  /// ```
  ///
  /// A build without the pragma, whose ``SQLiteLibrary/isForeignKeyCheckAvailable`` is `false`,
  /// such as Turso, cannot tell a database without violations from one it did not check, so this
  /// throws there rather than report none.
  ///
  /// - Returns: The violations in the order SQLite reports them, or an empty array when there are
  ///   none.
  /// - Throws: ``SQLiteFeatureUnavailableError`` with ``SQLiteLibraryFeature/foreignKeyCheck`` when
  ///   the library does not implement the check, or a ``SQLiteError`` when the check cannot run.
  public borrowing func foreignKeyViolations() throws -> [OrbitDatabaseForeignKeyViolation] {
    guard sqlite.isForeignKeyCheckAvailable else {
      throw SQLiteFeatureUnavailableError(libraryName: sqlite.name, feature: .foreignKeyCheck)
    }
    var violations: [OrbitDatabaseForeignKeyViolation] = []
    var cursor = try rowCursor(SQLQueryExpression("PRAGMA foreign_key_check"))
    while var row = try cursor.next() {
      violations.append(
        OrbitDatabaseForeignKeyViolation(
          table: try row.decode(String.self),
          rowID: try row.decode(Int64?.self),
          parentTable: try row.decode(String.self),
          foreignKeyIndex: try row.decode(Int.self)
        )
      )
    }
    return violations
  }
}
