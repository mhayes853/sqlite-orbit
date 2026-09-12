/// A transaction or connection lent by a native SQLite driver.
///
/// ``SQLiteReadTransaction``, ``SQLiteWriteTransaction``, ``SQLiteReadConnection``, and
/// ``SQLiteWriteConnection`` all conform, so code that needs what lies beneath them — the raw
/// connection, the SQLite build it runs against, or the configuration it was opened with — is
/// written once for every one of them. Everything ``OrbitDatabaseReadTransaction`` reads is
/// available as well, since this refines it.
///
/// ```swift
/// func isEncrypted<Transaction>(_ transaction: borrowing Transaction) -> Bool
/// where Transaction: SQLiteTransaction, Transaction: ~Copyable, Transaction: ~Escapable {
///   transaction.configuration.key != nil
/// }
///
/// let encrypted = try await database.read { isEncrypted($0) }
/// ```
public protocol SQLiteTransaction: OrbitDatabaseReadTransaction, ~Copyable, ~Escapable {
  /// The underlying `sqlite3 *`.
  ///
  /// This is the escape hatch for work the package does not model. It is only valid for the
  /// duration of the access that lent the transaction or connection.
  var sqliteConnection: OpaquePointer { get }

  /// The SQLite build the connection runs against, so raw work uses the same one.
  var sqlite: SQLiteLibrary { get }

  /// The configuration the connection was opened with.
  ///
  /// This is the configuration the driver was given. What a driver adds for a connection's role,
  /// such as the `PRAGMA query_only` a pool's readers run, is not part of it, and neither is a
  /// change an access makes to the connection's settings, such as its busy timeout.
  var configuration: SQLiteConfiguration { get }
}
