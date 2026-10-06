/// Where a committed database transaction was performed.
///
/// ```swift
/// let localOnly = OrbitValueObservation
///   .tracking { try $0.fetchOne("SELECT count(*) FROM reminders") { $0[0].integerValue } }
///   .filterTransactions { $0.origin == .local }
/// ```
public enum OrbitDatabaseTransactionOrigin: Hashable, Sendable {
  /// The transaction was performed by a database handle in this process.
  case local

  /// The transaction was announced by another process.
  case external
}

/// A successfully committed database transaction.
///
/// ```swift
/// func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
///   if commit.origin == .external { logger.info("another process wrote") }
/// }
/// ```
public struct OrbitDatabaseCommit: Hashable, Sendable {
  /// Where the transaction was performed.
  public let origin: OrbitDatabaseTransactionOrigin

  /// The database region changed by the transaction.
  public let region: OrbitDatabaseRegion

  /// Creates a commit.
  ///
  /// - Parameters:
  ///   - origin: Where the transaction was performed.
  ///   - region: The database region changed by the transaction. Defaults to the full database
  ///     for callers that cannot determine a more precise region.
  public init(
    origin: OrbitDatabaseTransactionOrigin,
    region: OrbitDatabaseRegion = .fullDatabase
  ) {
    self.origin = origin
    self.region = region
  }
}

/// Observes database reads and the lifecycle of database write transactions.
///
/// A read or write transaction performed through the observed handle calls ``databaseDidRead(in:)``
/// for each read region it publishes. A write transaction also calls ``databaseDidChange(in:)``
/// for each changed region. After its access closure returns it calls
/// ``databaseWillCommit(_:)``, while those changes are still visible through the transaction, and
/// then exactly one of ``databaseDidCommit(_:)`` and ``databaseDidRollback()``. A transaction
/// reported by another handle in this process, another process, or a driver that supports
/// overlapping write transactions reports its aggregate region followed immediately by
/// `databaseDidCommit` because it is observed after the commit succeeds.
///
/// A change made through the observed handle outside a transaction, such as in
/// ``OrbitDatabaseWriter/writeWithoutTransaction(_:)``, where SQLite commits each statement on its
/// own as it finishes, is reported in that same shape: its regions followed by
/// `databaseDidCommit` with a ``OrbitDatabaseTransactionOrigin/local`` origin, and no
/// `databaseWillCommit`, since there is no moment before the commit to observe. Such a change is
/// reported as committed even when its statement then fails, because an observer that fetches
/// again needlessly costs less than one that misses a change.
///
/// Prefer ``OrbitValueObservation`` for tracking a query; conform to this protocol when you need
/// the transaction lifecycle itself.
///
/// ```swift
/// final class CommitLogger: OrbitDatabaseTransactionObserver {
///   func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
///     logger.info("commit from \(String(describing: commit.origin))")
///   }
/// }
///
/// let subscription = try database.subscribe(transactionObserver: CommitLogger())
/// ```
public protocol OrbitDatabaseTransactionObserver: Sendable {
  /// Called when a transaction reads a database region.
  ///
  /// Read notifications are immediate and are not paired with a commit or rollback. The callback
  /// must not access the database.
  ///
  /// - Parameter region: The region the transaction may have read.
  func databaseDidRead(in region: OrbitDatabaseRegion)

  /// Called when a transaction may have changed a database region.
  ///
  /// A local change remains provisional until ``databaseDidCommit(_:)``. If the transaction rolls
  /// back, ``databaseDidRollback()`` follows instead. A local change made outside a transaction is
  /// followed by `databaseDidCommit` once its statement finishes. A change reported by another
  /// handle is already committed and is followed immediately by `databaseDidCommit`. The callback
  /// must not access the database.
  ///
  /// - Parameter region: The region the transaction may have changed.
  func databaseDidChange(in region: OrbitDatabaseRegion)

  /// Called before a local transaction commits.
  ///
  /// The transaction exposes the read capability, so its structured-query APIs can inspect the
  /// final transaction state but cannot mutate it. Throwing aborts the write transaction. Changes
  /// made outside a transaction commit statement by statement and are not preceded by this call.
  ///
  /// - Parameter transaction: The committing transaction, readable but not writable.
  /// - Throws: Any error, which rolls the write transaction back and fails the write.
  func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws

  /// Called after a transaction commits.
  ///
  /// - Parameter commit: The transaction that committed, and where it came from.
  func databaseDidCommit(_ commit: OrbitDatabaseCommit)

  /// Called after a local transaction rolls back.
  func databaseDidRollback()
}

extension OrbitDatabaseTransactionObserver {
  /// Ignores a read region.
  ///
  /// - Parameter region: The region the transaction may have read.
  public func databaseDidRead(in region: OrbitDatabaseRegion) {}

  /// Ignores a changed region.
  ///
  /// - Parameter region: The region the transaction may have changed.
  public func databaseDidChange(in region: OrbitDatabaseRegion) {}

  /// Ignores the transaction, letting it commit.
  ///
  /// - Parameter transaction: The committing transaction.
  public func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws {}

  /// Ignores the commit.
  ///
  /// - Parameter commit: The transaction that committed.
  public func databaseDidCommit(_ commit: OrbitDatabaseCommit) {}

  /// Ignores the rollback.
  public func databaseDidRollback() {}
}

/// A database that lends reads and reports observable transactions.
///
/// This is what ``OrbitValueObservation`` needs from a database, and what ``OrbitIPCDatabase``
/// provides.
/// A read-only facade can conform without exposing write operations; mutable databases also
/// conform to ``OrbitDatabaseWriter``.
///
/// ```swift
/// let subscription = try database.subscribe(transactionObserver: CommitLogger())
/// ```
public protocol OrbitObservableDatabase: AnyObject, OrbitDatabaseReader {
  /// Captures the finite set of writers active now for observation coordination.
  ///
  /// The snapshot can include the writer currently reporting a commit. Its completion must be
  /// reported only after all observers have received that commit. Writers that begin after this
  /// call do not extend the snapshot. A database without concurrent writers may return `nil`.
  func captureActiveWriters() -> (any OrbitDatabaseWriterBarrier)?

  /// Registers `transactionObserver` for commits concerning `region` until the returned
  /// subscription is cancelled.
  ///
  /// The region is a lower bound: a commit that overlaps it is always reported, and a commit
  /// outside it may or may not be. A database that coordinates with other processes can use it to
  /// spare them from announcing commits the observer does not care about. A database whose
  /// transactions all happen in this process can ignore it, since observers filter those
  /// transactions themselves. Reads and the callbacks of this handle's own transactions are
  /// reported regardless of the region.
  ///
  /// ```swift
  /// let subscription = try database.subscribe(
  ///   transactionObserver: CommitLogger(),
  ///   region: OrbitDatabaseRegion(table: "reminders")
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - transactionObserver: The observer to register.
  ///   - region: The region whose commits the observer must be told about.
  /// - Returns: A subscription that unregisters the observer when cancelled or released, and
  ///   through which its region can change.
  /// - Throws: An error if the observer cannot be registered.
  func subscribe(
    transactionObserver: any OrbitDatabaseTransactionObserver,
    region: OrbitDatabaseRegion
  ) throws -> OrbitRegionSubscription
}

extension OrbitObservableDatabase {
  /// Returns no coordination snapshot for databases without concurrent writers.
  public func captureActiveWriters() -> (any OrbitDatabaseWriterBarrier)? { nil }

  /// Registers `transactionObserver` for every commit until the returned subscription is
  /// cancelled.
  ///
  /// ```swift
  /// let subscription = try database.subscribe(transactionObserver: CommitLogger())
  /// ```
  ///
  /// - Parameter transactionObserver: The observer to register.
  /// - Returns: A subscription that unregisters the observer when cancelled or released.
  /// - Throws: An error if the observer cannot be registered.
  public func subscribe(
    transactionObserver: any OrbitDatabaseTransactionObserver
  ) throws -> OrbitRegionSubscription {
    try subscribe(transactionObserver: transactionObserver, region: .fullDatabase)
  }
}

/// A writer whose database file can be opened and coordinated across processes.
///
/// Conformance promises that the writer type can share a database with another process. When such
/// a type also has process-local configurations, callers must supply a multiprocess-capable
/// instance. ``OrbitIPCDatabase`` additionally requires the writer to conform to
/// ``OrbitObservableDatabase`` so it can combine local transaction events with peer announcements.
public protocol OrbitMultiprocessDatabaseWriter: OrbitDatabaseWriter, OrbitSuspendable {
  /// The identifier an ``OrbitIPCDatabase`` uses when its caller does not supply one.
  var defaultIdentifier: OrbitDatabaseIdentifier { get }
}

final class OrbitDatabaseTransactionObservers: OrbitDatabaseTransactionObserver {
  private let observers = Lock(IdentifiedRegistry<any OrbitDatabaseTransactionObserver>())

  /// Registers `observer` on behalf of a database whose transactions all happen in this process,
  /// which reports every one of them whatever the region.
  func subscribe(
    _ observer: any OrbitDatabaseTransactionObserver,
    region: OrbitDatabaseRegion = .fullDatabase
  ) -> OrbitRegionSubscription {
    let identifier = observers.withLock { $0.insert(observer) }
    return OrbitRegionSubscription(region: region) { [weak self] in
      _ = self?.observers.withLock { $0.remove(identifier) }
    }
  }

  func databaseWillCommit(_ transaction: borrowing SQLiteReadTransaction) throws {
    for observer in observers.withLock({ $0.all }) {
      try observer.databaseWillCommit(transaction)
    }
  }

  func databaseDidRead(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidRead(in: region)
    }
  }

  func databaseDidChange(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidChange(in: region)
    }
  }

  func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidCommit(commit)
    }
  }

  func databaseDidRollback() {
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidRollback()
    }
  }
}
