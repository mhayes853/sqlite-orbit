/// A database that can free the memory it is able to rebuild on demand.
///
/// A release frees what a database keeps only to go faster: idle prepared statements, unused
/// page-cache pages, and connections it can open again. It changes nothing any access sees; later
/// accesses compile statements and read pages again as they need them.
///
/// A release holds up no other access. A connection in use releases when its current access ends,
/// and a pool's readers in use close when their reads end. A release runs no SQL and works while a
/// database is suspended. Statements and cursors in use keep working.
///
/// Nothing calls this automatically. Call it when the system asks for memory back:
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
  /// It never fails, and cancelling the calling task does not stop it.
  func releaseMemory() async
}
