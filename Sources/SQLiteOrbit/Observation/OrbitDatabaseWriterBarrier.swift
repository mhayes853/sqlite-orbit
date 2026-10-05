/// A finite snapshot of database writer loans that can be awaited.
///
/// A connection pool or observable database captures the writers active when
/// `captureActiveWriters()` is called. Later writers cannot extend the snapshot. Each captured
/// writer completes after its entire loan ends, including cleanup and any commit publication.
/// Observation uses this to coalesce refetches without waiting for an unbounded stream of writes.
public protocol OrbitDatabaseWriterBarrier: Sendable {
  /// Whether a writer captured by this snapshot has not yet completed.
  var hasActiveWriters: Bool { get }

  /// Waits until every writer captured by this snapshot has completed.
  ///
  /// Waiting neither blocks a thread nor prevents later writers from running. A writer must
  /// finish its own access before waiting for a snapshot that includes it.
  func wait() async
}
