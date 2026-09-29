/// A database that can stop its writer from retaining a lock while its process may be suspended.
///
/// Suspension refuses new writes and interrupts an active write. Reads may continue where the
/// database driver can perform them without retaining a write lock. Calling either method more
/// than once has no additional effect.
public protocol OrbitSuspendable: Sendable {
  /// Whether the database currently refuses writes that could hold its writer lock.
  var isSuspended: Bool { get }

  /// Begins refusing writes and interrupts the one currently executing, if any.
  ///
  /// This call does not wait for an interrupted write to roll back.
  func suspend()

  /// Allows new writes again.
  func resume()
}

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
