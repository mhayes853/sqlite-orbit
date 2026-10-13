/// Accumulates the regions an observed database access reads, changes, and commits.
///
/// Use a recorder with a transaction or connection's `withObservation` method, or register it
/// through ``OrbitObservableDatabase/subscribe(transactionObserver:)``. Each region is the union
/// of the corresponding notifications received while the recorder is registered.
///
/// ``changedRegion`` includes provisional changes that later roll back. ``committedRegion`` uses
/// each commit's complete region, including changes made before the recorder was registered.
/// A recorder scoped inside a transaction body stops observing before that transaction commits;
/// observe the entire transaction when its commit or rollback must be recorded.
public final class OrbitDatabaseRegionRecorder: OrbitDatabaseTransactionObserver, Sendable {
  private struct Regions {
    var read = OrbitDatabaseRegion.empty
    var changed = OrbitDatabaseRegion.empty
    var committed = OrbitDatabaseRegion.empty
    var hasCommitted = false
  }

  private let regions = Lock(Regions())

  /// Creates a recorder whose regions are empty.
  public init() {}

  /// The union of the read regions reported to this recorder.
  public var readRegion: OrbitDatabaseRegion { regions.withLock { $0.read } }

  /// The union of every provisional change reported to this recorder, including rolled-back changes.
  public var changedRegion: OrbitDatabaseRegion { regions.withLock { $0.changed } }

  /// The union of the complete regions carried by commits reported to this recorder.
  public var committedRegion: OrbitDatabaseRegion { regions.withLock { $0.committed } }

  /// Whether this recorder received a commit, including one whose region is empty.
  public var hasCommitted: Bool { regions.withLock { $0.hasCommitted } }

  /// Records a read region.
  public func databaseDidRead(in region: OrbitDatabaseRegion) {
    regions.withLock { $0.read.formUnion(region) }
  }

  /// Records a provisional change. A later rollback does not remove it from ``changedRegion``.
  public func databaseDidChange(in region: OrbitDatabaseRegion) {
    regions.withLock { $0.changed.formUnion(region) }
  }

  /// Records the commit's complete region, independently of earlier change notifications.
  public func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    regions.withLock { regions in
      regions.committed.formUnion(commit.region)
      regions.hasCommitted = true
    }
  }
}
