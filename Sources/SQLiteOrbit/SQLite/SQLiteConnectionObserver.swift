/// Observes the reads, changes, and transaction lifecycle of one SQLite connection access.
///
/// Register an observer with a borrowed connection or transaction's `withObservation` method.
/// Events concern only that access, including nested scopes and transactions. Read and change
/// callbacks must not access the database. Before commit, the readable transaction can inspect
/// the final state; throwing from that callback aborts the transaction.
public protocol SQLiteConnectionObserver: Sendable {
  /// The connection may have read this region.
  func connectionDidRead(in region: OrbitDatabaseRegion)

  /// The connection may have changed this region. Changes remain provisional until commit.
  func connectionDidChange(in region: OrbitDatabaseRegion)

  /// The explicit write transaction is about to commit. Throwing rolls it back.
  func connectionWillCommit(_ transaction: borrowing SQLiteReadTransaction) throws

  /// Changes to this region committed successfully.
  ///
  /// Statements outside an explicit transaction commit without a preceding `connectionWillCommit`.
  func connectionDidCommit(in region: OrbitDatabaseRegion)

  /// The explicit write transaction rolled back.
  func connectionDidRollback()
}

extension SQLiteConnectionObserver {
  public func connectionDidRead(in region: OrbitDatabaseRegion) {}
  public func connectionDidChange(in region: OrbitDatabaseRegion) {}
  public func connectionWillCommit(_ transaction: borrowing SQLiteReadTransaction) throws {}
  public func connectionDidCommit(in region: OrbitDatabaseRegion) {}
  public func connectionDidRollback() {}
}
