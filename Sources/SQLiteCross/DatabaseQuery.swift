public import StructuredQueriesSQLite

/// The transaction capability a query requires.
public protocol DatabaseAccess: Sendable {}

/// The capability of a query that only reads.
public enum DatabaseReadAccess: DatabaseAccess {}

/// The capability of a query that may write.
public enum DatabaseWriteAccess: DatabaseAccess {}

/// A query paired with the transaction capability it requires.
///
/// A value of this type can only be built from a statement whose capability the type system has
/// already established, so a driver can run one without checking it again. This is what keeps
/// ``DatabaseReadTransaction`` from being handed a mutation: no `DatabaseQuery<DatabaseReadAccess>`
/// can be built from a statement that writes.
///
/// The capability is read off the statement's own position in the Structured Queries protocol
/// hierarchy rather than a list of known statement types, so statements the library keeps private,
/// such as the one behind `union`, are classified correctly too.
public struct DatabaseQuery<Access: DatabaseAccess>: Sendable {
  /// The query to run.
  public let fragment: QueryFragment

  private init(unchecked fragment: QueryFragment) {
    self.fragment = fragment
  }
}

extension DatabaseQuery where Access == DatabaseReadAccess {
  /// Wraps a `SELECT`-shaped statement.
  ///
  /// This covers `Select`, `Where`, `Table`, `Values`, `With` over a select, and the compound
  /// selects produced by `union`, `intersect`, and `except`.
  public init(_ statement: some PartialSelectStatement) {
    self.init(unchecked: statement.query)
  }

  /// Wraps raw SQL.
  ///
  /// Raw SQL is ordinary to write, but its capability cannot be established from its type, so it
  /// is accepted by read and write transactions alike. The caller is stating that the SQL reads.
  public init<QueryValue>(_ statement: SQLQueryExpression<QueryValue>) {
    self.init(unchecked: statement.query)
  }
}

extension DatabaseQuery where Access == DatabaseWriteAccess {
  /// Wraps any statement.
  ///
  /// Every statement can run in a write transaction, including `INSERT`, `UPDATE`, `DELETE`, and
  /// the temporary trigger and view definitions from the SQLite layer.
  public init(_ statement: some Statement) {
    self.init(unchecked: statement.query)
  }
}
