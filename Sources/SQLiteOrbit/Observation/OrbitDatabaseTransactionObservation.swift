/// Where a committed database transaction was performed.
///
/// ```swift
/// let localOnly = OrbitValueObservation
///   .tracking { try $0.fetchCount(Reminder.all) }
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

  let activeWriterBarrier: SQLitePoolWriterBarrier?

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
    self.activeWriterBarrier = nil
  }

  init(
    origin: OrbitDatabaseTransactionOrigin,
    region: OrbitDatabaseRegion,
    activeWriterBarrier: SQLitePoolWriterBarrier?
  ) {
    self.origin = origin
    self.region = region
    self.activeWriterBarrier = activeWriterBarrier
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.origin == rhs.origin && lhs.region == rhs.region
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(origin)
    hasher.combine(region)
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
  /// back, ``databaseDidRollback()`` follows instead. A change reported by another handle is
  /// already committed and is followed immediately by `databaseDidCommit`. The callback must not
  /// access the database.
  ///
  /// - Parameter region: The region the transaction may have changed.
  func databaseDidChange(in region: OrbitDatabaseRegion)

  /// Called before a local transaction commits.
  ///
  /// The transaction exposes the read capability, so its structured-query APIs can inspect the
  /// final transaction state but cannot mutate it. Throwing aborts the write transaction.
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

/// A database whose reads and write transactions can be observed.
///
/// This is what ``OrbitValueObservation`` needs from a database, and what ``OrbitDatabase``
/// provides.
///
/// ```swift
/// let subscription = try database.subscribe(transactionObserver: CommitLogger())
/// ```
public protocol OrbitObservableDatabase: AnyObject, OrbitDatabaseWriter {
  /// Registers `transactionObserver` until the returned subscription is cancelled.
  ///
  /// - Parameter transactionObserver: The observer to register.
  /// - Returns: A subscription that unregisters the observer when cancelled or released.
  /// - Throws: An error if the observer cannot be registered.
  func subscribe(
    transactionObserver: any OrbitDatabaseTransactionObserver
  ) throws -> OrbitSubscription
}

final class OrbitDatabaseTransactionObservers: Sendable {
  private let observers = Lock(IdentifiedRegistry<any OrbitDatabaseTransactionObserver>())

  func subscribe(
    _ observer: any OrbitDatabaseTransactionObserver
  ) -> OrbitSubscription {
    let identifier = observers.withLock { $0.insert(observer) }
    return OrbitSubscription { [weak self] in
      _ = self?.observers.withLock { $0.remove(identifier) }
    }
  }

  func willCommit(_ transaction: borrowing SQLiteReadTransaction) throws {
    for observer in observers.withLock({ $0.all }) {
      try observer.databaseWillCommit(transaction)
    }
  }

  func didRead(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidRead(in: region)
    }
  }

  func didChange(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidChange(in: region)
    }
  }

  func didCommit(
    origin: OrbitDatabaseTransactionOrigin,
    region: OrbitDatabaseRegion,
    activeWriterBarrier: SQLitePoolWriterBarrier? = nil
  ) {
    let commit = OrbitDatabaseCommit(
      origin: origin,
      region: region,
      activeWriterBarrier: activeWriterBarrier
    )
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidCommit(commit)
    }
  }

  func didRollback() {
    for observer in observers.withLock({ $0.all }) {
      observer.databaseDidRollback()
    }
  }
}

/// Routes one database access to its database-wide observers and any observers scoped to it.
///
/// A context is confined to one serialized SQLite connection access. Keeping scoped observers here
/// instead of in the database-wide registry prevents concurrent pool reads from seeing one
/// another's events.
final class OrbitDatabaseTransactionObservationContext {
  private let databaseObservers: OrbitDatabaseTransactionObservers?
  private var scopedObservers: [any OrbitDatabaseTransactionObserver] = []
  private(set) var changedRegion = OrbitDatabaseRegion.empty

  init(databaseObservers: OrbitDatabaseTransactionObservers?) {
    self.databaseObservers = databaseObservers
  }

  func withObserver<Result: ~Copyable>(
    _ observer: any OrbitDatabaseTransactionObserver,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    scopedObservers.append(observer)
    defer { scopedObservers.removeLast() }
    return try operation()
  }

  func didRead(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    databaseObservers?.didRead(in: region)
    for observer in scopedObservers {
      observer.databaseDidRead(in: region)
    }
  }

  func didChange(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    changedRegion.formUnion(region)
    databaseObservers?.didChange(in: region)
    for observer in scopedObservers {
      observer.databaseDidChange(in: region)
    }
  }
}
