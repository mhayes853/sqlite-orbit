#if StructuredQueries
  public import StructuredQueriesSQLite
#endif

/// The transaction capability a query requires.
///
/// Only ``OrbitDatabaseReadAccess`` and ``OrbitDatabaseWriteAccess`` conform. The protocol exists
/// to make ``OrbitDatabaseQuery`` generic over the two, and has no requirements of its own.
///
/// ```swift
/// func run<Access: OrbitDatabaseAccess>(_ query: OrbitDatabaseQuery<Access>) {
///   print(query.sql)
/// }
/// ```
public protocol OrbitDatabaseAccess: Sendable {}

/// The capability of a query that only reads.
///
/// An uninhabited type used only as a marker.
///
/// ```swift
/// let query = OrbitDatabaseQuery<OrbitDatabaseReadAccess>("SELECT * FROM reminders")
/// ```
public enum OrbitDatabaseReadAccess: OrbitDatabaseAccess {}

/// The capability of a query that may write.
///
/// An uninhabited type used only as a marker.
///
/// ```swift
/// let query = OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(
///   "DELETE FROM reminders WHERE is_completed"
/// )
/// ```
public enum OrbitDatabaseWriteAccess: OrbitDatabaseAccess {}

/// A query paired with the transaction capability it requires.
///
/// ``OrbitDatabaseReadTransaction`` only accepts `OrbitDatabaseQuery<OrbitDatabaseReadAccess>`, so
/// a read transaction cannot be handed a mutation it was never meant to run. Raw SQL cannot show
/// its capability through its type, so a read transaction checks each statement when it prepares
/// it, and refuses one that SQLite reports may write with a ``SQLiteError`` whose code is
/// ``SQLiteResultCode/readOnly``. A write transaction may write, so it runs a read query as it is.
///
/// ```swift
/// try await database.read { transaction in
///   var cursor = try transaction.rowCursor(
///     OrbitDatabaseQuery<OrbitDatabaseReadAccess>("SELECT title FROM reminders"),
///     cached: false
///   )
///   return try cursor.forEach { _ in }
/// }
/// ```
public struct OrbitDatabaseQuery<Access: OrbitDatabaseAccess>: Sendable {
  /// The SQL to run.
  public let sql: SQL

  init(unchecked sql: SQL) {
    self.sql = sql
  }
}

extension OrbitDatabaseQuery where Access == OrbitDatabaseReadAccess {
  /// Wraps SQL that only reads.
  ///
  /// A read transaction checks the statement when it prepares it, so SQL that may write is
  /// refused there rather than run.
  ///
  /// ```swift
  /// let query = OrbitDatabaseQuery<OrbitDatabaseReadAccess>(
  ///   "SELECT title FROM reminders WHERE id = \(id)"
  /// )
  /// ```
  ///
  /// - Parameter sql: The SQL to run.
  public init(_ sql: SQL) {
    self.init(unchecked: sql)
  }
}

extension OrbitDatabaseQuery where Access == OrbitDatabaseWriteAccess {
  /// Wraps SQL that may write.
  ///
  /// ```swift
  /// let query = OrbitDatabaseQuery<OrbitDatabaseWriteAccess>(
  ///   "INSERT INTO reminders (title) VALUES (\(title))"
  /// )
  /// ```
  ///
  /// - Parameter sql: The SQL to run.
  public init(_ sql: SQL) {
    self.init(unchecked: sql)
  }
}

#if StructuredQueries
  extension OrbitDatabaseQuery where Access == OrbitDatabaseReadAccess {
    /// Wraps a `SELECT`-shaped statement.
    ///
    /// This covers `Select`, `Where`, `Table`, `Values`, `With` over a select, and the compound
    /// selects produced by `union`, `intersect`, and `except`. The capability is read off the
    /// statement's own position in the Structured Queries protocol hierarchy rather than a list of
    /// known statement types, so statements the library keeps private, such as the one behind
    /// `union`, are classified correctly too.
    ///
    /// ```swift
    /// let query = OrbitDatabaseQuery<OrbitDatabaseReadAccess>(Reminder.where { !$0.isCompleted })
    /// ```
    ///
    /// - Parameter statement: The statement to run.
    public init(_ statement: some PartialSelectStatement) {
      self.init(unchecked: SQL(fragment: statement.query))
    }

    /// Wraps typed raw SQL.
    ///
    /// ```swift
    /// let query = OrbitDatabaseQuery<OrbitDatabaseReadAccess>(
    ///   #sql("SELECT count(*) FROM reminders", as: Int.self)
    /// )
    /// ```
    ///
    /// - Parameter statement: The SQL to run.
    public init<QueryValue>(_ statement: SQLQueryExpression<QueryValue>) {
      self.init(unchecked: SQL(fragment: statement.query))
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
      self.init(unchecked: SQL(fragment: statement.query))
    }
  }
#endif
