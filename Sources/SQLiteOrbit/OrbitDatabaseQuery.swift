public import StructuredQueriesSQLite

/// The transaction capability a query requires.
///
/// Only ``OrbitDatabaseReadAccess`` and ``OrbitDatabaseWriteAccess`` conform. The protocol exists
/// to make ``OrbitDatabaseQuery`` generic over the two, and has no requirements of its own.
///
/// ```swift
/// func run<Access: OrbitDatabaseAccess>(_ query: OrbitDatabaseQuery<Access>) {
///   print(query.fragment)
/// }
/// ```
public protocol OrbitDatabaseAccess: Sendable {}

/// The capability of a query that only reads.
///
/// An uninhabited type used only as a marker.
///
/// ```swift
/// let query = OrbitDatabaseQuery<OrbitDatabaseReadAccess>(Reminder.all)
/// ```
public enum OrbitDatabaseReadAccess: OrbitDatabaseAccess {}

/// The capability of a query that may write.
///
/// An uninhabited type used only as a marker.
///
/// ```swift
/// let query = OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(Reminder.where(\.isCompleted).delete())
/// ```
public enum OrbitDatabaseWriteAccess: OrbitDatabaseAccess {}

/// A query paired with the transaction capability it requires.
///
/// A value of this type can only be built from a statement whose capability the type system has
/// already established, so a driver can run one without checking it again. This is what keeps
/// ``OrbitDatabaseReadTransaction`` from being handed a mutation: no
/// `OrbitDatabaseQuery<OrbitDatabaseReadAccess>` can be built from a statement that writes.
///
/// The capability is read off the statement's own position in the Structured Queries protocol
/// hierarchy rather than a list of known statement types, so statements the library keeps private,
/// such as the one behind `union`, are classified correctly too.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.rowCursor(
///     OrbitDatabaseQuery<OrbitDatabaseReadAccess>(Reminder.all),
///     cached: false
///   )
///   return try cursor.forEach { _ in }
/// }
/// ```
public struct OrbitDatabaseQuery<Access: OrbitDatabaseAccess>: Sendable {
  /// The query to run.
  public let fragment: QueryFragment

  private init(unchecked fragment: QueryFragment) {
    self.fragment = fragment
  }
}

extension OrbitDatabaseQuery where Access == OrbitDatabaseReadAccess {
  /// Wraps a `SELECT`-shaped statement.
  ///
  /// This covers `Select`, `Where`, `Table`, `Values`, `With` over a select, and the compound
  /// selects produced by `union`, `intersect`, and `except`.
  ///
  /// ```swift
  /// let query = OrbitDatabaseQuery<OrbitDatabaseReadAccess>(Reminder.where { !$0.isCompleted })
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  public init(_ statement: some PartialSelectStatement) {
    self.init(unchecked: statement.query)
  }

  /// Wraps raw SQL.
  ///
  /// Raw SQL is ordinary to write, but its capability cannot be established from its type, so it
  /// is accepted by read and write transactions alike. The caller is stating that the SQL reads.
  ///
  /// ```swift
  /// let query = OrbitDatabaseQuery<OrbitDatabaseReadAccess>(
  ///   #sql("SELECT count(*) FROM reminders", as: Int.self)
  /// )
  /// ```
  ///
  /// - Parameter statement: The SQL to run.
  public init<QueryValue>(_ statement: SQLQueryExpression<QueryValue>) {
    self.init(unchecked: statement.query)
  }
}

extension OrbitDatabaseQuery where Access == OrbitDatabaseWriteAccess {
  /// Wraps any statement.
  ///
  /// Every statement can run in a write transaction, including `INSERT`, `UPDATE`, `DELETE`, and
  /// the temporary trigger and view definitions from the SQLite layer.
  ///
  /// ```swift
  /// let query = OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(
  ///   Reminder.insert { Reminder(id: 1, title: "Get milk") }
  /// )
  /// ```
  ///
  /// - Parameter statement: The statement to run.
  public init(_ statement: some Statement) {
    self.init(unchecked: statement.query)
  }
}
