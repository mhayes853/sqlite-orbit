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
