/// A database that can free the memory it is able to rebuild on demand.
///
/// What a database frees is what it would otherwise keep only to go faster: SQLite's page caches,
/// the prepared statements it keeps idle for reuse, and connections it can open again. Nothing it
/// frees changes what the database holds or what any access sees, and accesses after the release
/// rebuild what they need, at the cost of compiling statements and reading pages again.
///
/// A release never holds up other accesses. A connection that is idle releases right away, and one
/// that is in use releases once its current access ends. A pool, such as ``SQLitePool``, closes its
/// idle readers at once and each reader in use when its read ends, without waiting for those, and
/// returns once each of its writers has released between two of its accesses. A driver with a
/// single connection, such as ``SQLiteQueue``, runs the release on it as soon as the accesses
/// already waiting for it are done, and returns then. Statements and cursors in use keep working
/// throughout.
///
/// Nothing calls this on its own. An app that wants to give memory back when the system runs
/// low, or when it moves to the background, calls it from the notification it cares about:
///
/// ```swift
/// let observer = NotificationCenter.default.addObserver(
///   forName: UIApplication.didReceiveMemoryWarningNotification,
///   object: nil,
///   queue: nil
/// ) { _ in
///   Task { await database.releaseMemory() }
/// }
/// ```
public protocol OrbitMemoryReleasing: Sendable {
  /// Frees the memory the database can rebuild on demand.
  ///
  /// The call returns once every connection the driver waits for has released. It never fails: a
  /// release is only ever an optimization, so a connection that cannot release, such as one that
  /// is closing, is left as it is.
  func releaseMemory() async
}
