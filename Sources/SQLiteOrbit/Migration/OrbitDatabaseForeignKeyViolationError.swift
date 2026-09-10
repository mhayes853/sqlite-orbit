/// Reported when a migration leaves rows that violate a foreign key constraint.
///
/// A migration registered with ``OrbitDatabaseMigrator/ForeignKeyChecks/deferred`` runs with
/// foreign keys off and has the whole database checked just before it commits. When that check
/// finds violations, the migration is rolled back and this error lists them as
/// `PRAGMA foreign_key_check` reports them. Migrations that committed before it stay applied.
///
/// ```swift
/// do {
///   try await migrator.migrate(database)
/// } catch let error as OrbitDatabaseForeignKeyViolationError {
///   for violation in error.violations {
///     print("\(violation.table) row \(violation.rowID ?? 0) has no \(violation.parentTable)")
///   }
/// }
/// ```
public struct OrbitDatabaseForeignKeyViolationError: Error, Hashable, CustomStringConvertible {
  /// One row whose foreign key refers to a row that does not exist.
  public struct Violation: Hashable, Sendable {
    /// The table holding the row with the dangling reference.
    public let table: String

    /// The row's rowid, or `nil` for a row of a `WITHOUT ROWID` table.
    public let rowID: Int64?

    /// The table the row's foreign key refers to.
    public let parentTable: String

    /// Which of the table's foreign keys is violated, numbered as `PRAGMA foreign_key_list`
    /// numbers them.
    public let foreignKeyIndex: Int
  }

  /// The identifier of the migration that left the violations, which was rolled back.
  public let migration: String

  /// Every violation the check found, in the order SQLite reported them.
  public let violations: [Violation]

  /// Names the migration and the violations it left.
  public var description: String {
    let rows = violations.map { violation in
      let row = violation.rowID.map { "row \($0)" } ?? "a row"
      return "\(row) of \(violation.table) refers to a missing \(violation.parentTable)"
    }
    return """
      Migration "\(migration)" was rolled back because it violates foreign key constraints: \
      \(rows.joined(separator: "; ")).
      """
  }
}
