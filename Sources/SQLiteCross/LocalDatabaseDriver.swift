/// Adapts a local SQLite driver to cross-process transaction observation.
///
/// Implementations can be backed by GRDB, direct SQLite calls, or another local SQLite driver.
/// The protocol deliberately exposes no driver-specific connection or query types.
public protocol LocalDatabaseDriver: Sendable {
  /// The stable identity shared by processes that open this database.
  var identifier: DatabaseIdentifier { get }

  /// Begins observing successful commits performed through this local driver.
  ///
  /// Rollbacks must not invoke `onCommit`. The handler may be invoked on any executor.
  func subscribeToLocalCommits(
    _ onCommit: @escaping @Sendable (DatabaseChangeRegion) -> Void
  ) throws -> any TransactionSubscription

  /// Invalidates local observations after another process commits a change.
  ///
  /// Implementations must not report this invalidation back through subscriptions created by
  /// ``subscribeToLocalCommits(_:)``.
  func notifyChangesFromExternalCommit(in region: DatabaseChangeRegion) async throws
}
