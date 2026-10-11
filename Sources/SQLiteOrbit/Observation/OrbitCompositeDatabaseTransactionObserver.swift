/// A transaction observer that forwards every callback to the observers subscribed to it.
///
/// This is the building block a driver uses to implement
/// ``OrbitObservableDatabase/subscribe(transactionObserver:region:)``: it installs one composite on
/// each access it lends, and hands out subscriptions to it. Every member is told about every
/// transaction the composite is told about. The `region` given to ``subscribe(_:region:)`` is
/// recorded on the returned subscription but filters nothing, which suits a database whose
/// transactions all happen in this process, since observers filter those themselves.
///
/// Members are called in no particular order, on whichever thread reports the event, and are not
/// called while the composite holds its lock, so a member may subscribe or cancel others. An empty
/// read or changed region is not forwarded.
///
/// ```swift
/// final class MyDriver: OrbitObservableDatabase {
///   private let connection: SQLiteSerialConnection
///   private let observers = OrbitCompositeDatabaseTransactionObserver()
///
///   func read<Result: Sendable>(
///     _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
///   ) async throws -> Result {
///     try await connection.withReadConnection { connection in
///       try connection.transaction(observer: observers, body)
///     }
///   }
///
///   func subscribe(
///     transactionObserver: any OrbitDatabaseTransactionObserver,
///     region: OrbitDatabaseRegion
///   ) throws -> OrbitRegionSubscription {
///     observers.subscribe(transactionObserver, region: region)
///   }
///
///   // ...
/// }
/// ```
public final class OrbitCompositeDatabaseTransactionObserver: OrbitDatabaseTransactionObserver {
  private let observers = Lock(IdentifiedRegistry<any OrbitDatabaseTransactionObserver>())

  /// Creates a composite with no members.
  public init() {}

  /// Adds `observer` to the members this composite forwards to, until the returned subscription
  /// is cancelled or released.
  ///
  /// ```swift
  /// let subscription = observers.subscribe(CommitLogger())
  /// ```
  ///
  /// - Parameters:
  ///   - observer: The observer to forward every callback to.
  ///   - region: The region recorded on the returned subscription. It does not filter what
  ///     `observer` is told: every transaction is reported to it.
  /// - Returns: A subscription that removes `observer` when cancelled or released. Updating its
  ///   region has no effect on what is forwarded.
  public func subscribe(
    _ observer: any OrbitDatabaseTransactionObserver,
    region: OrbitDatabaseRegion = .fullDatabase
  ) -> OrbitRegionSubscription {
    let identifier = observers.withLock { $0.insert(observer) }
    return OrbitRegionSubscription(region: region) { [weak self] in
      _ = self?.observers.withLock { $0.remove(identifier) }
    }
  }

  /// Asks every member whether the transaction may commit, stopping at the first that throws.
  ///
  /// - Parameter transaction: The committing transaction, readable but not writable.
  /// - Throws: The first error a member throws, which rolls the transaction back.
  public func databaseWillCommit(_ transaction: borrowing SQLiteReadTransaction) throws {
    for observer in observers.withLock({ $0.all }) {
      try observer.databaseWillCommit(transaction)
    }
  }

  /// Tells every member about a read region, unless it is empty.
  ///
  /// - Parameter region: The region the transaction may have read.
  public func databaseDidRead(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidRead(in: region)
    }
  }

  /// Tells every member about a changed region, unless it is empty.
  ///
  /// - Parameter region: The region the transaction may have changed.
  public func databaseDidChange(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidChange(in: region)
    }
  }

  /// Tells every member about a commit.
  ///
  /// - Parameter commit: The transaction that committed.
  public func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidCommit(commit)
    }
  }

  /// Tells every member about a rollback.
  public func databaseDidRollback() {
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidRollback()
    }
  }
}
