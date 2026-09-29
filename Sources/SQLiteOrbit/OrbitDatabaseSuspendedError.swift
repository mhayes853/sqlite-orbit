/// Thrown by a write that its database refused or interrupted because the database is suspended.
///
/// A transactional write is rolled back. With `writeWithoutTransaction`, statements that finished
/// before suspension may already have committed. The write can be retried after resuming.
///
/// ```swift
/// do {
///   try await database.write { try $0.execute("INSERT INTO reminders (title) VALUES (\(title))") }
/// } catch is OrbitDatabaseSuspendedError {
///   // Retry the transaction once the database is resumed.
/// }
/// ```
public struct OrbitDatabaseSuspendedError: Error, Hashable, Sendable {
  /// The database that refused the write.
  public let databaseIdentifier: OrbitDatabaseIdentifier

  /// Creates an error for a write that `databaseIdentifier` refused while suspended.
  ///
  /// - Parameter databaseIdentifier: The database that refused the write.
  public init(databaseIdentifier: OrbitDatabaseIdentifier) {
    self.databaseIdentifier = databaseIdentifier
  }
}
