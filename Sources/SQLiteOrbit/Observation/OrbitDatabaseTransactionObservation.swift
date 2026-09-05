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

  /// Creates a commit.
  ///
  /// - Parameter origin: Where the transaction was performed.
  public init(origin: OrbitDatabaseTransactionOrigin) {
    self.origin = origin
  }
}

/// Observes the lifecycle of database write transactions.
///
/// A transaction performed through the observed handle calls ``databaseWillCommit(_:)`` after its
/// access closure returns, while its changes are still visible through the transaction. It then
/// calls exactly one of ``databaseDidCommit(_:)`` and ``databaseDidRollback()``. A transaction
/// reported by another handle in this process, or by another process, can only produce
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

/// A database whose write transactions can be observed.
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

/// The observers attached to one local database driver.
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

  func didCommit(origin: OrbitDatabaseTransactionOrigin) {
    let commit = OrbitDatabaseCommit(origin: origin)
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
