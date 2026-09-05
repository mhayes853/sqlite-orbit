/// Where a committed database transaction was performed.
///
/// ```swift
/// let localOnly = ValueObservation
///   .tracking { try $0.fetchCount(Reminder.all) }
///   .filterTransactions { $0.origin == .local }
/// ```
public enum DatabaseTransactionOrigin: Hashable, Sendable {
  /// The transaction was performed by a database handle in this process.
  case local

  /// The transaction was announced by another process.
  case external
}

/// A successfully committed database transaction.
///
/// ```swift
/// func databaseDidCommit(_ commit: DatabaseCommit) {
///   if commit.origin == .external { logger.info("another process wrote") }
/// }
/// ```
public struct DatabaseCommit: Hashable, Sendable {
  /// Where the transaction was performed.
  public let origin: DatabaseTransactionOrigin

  /// Creates a commit.
  ///
  /// - Parameter origin: Where the transaction was performed.
  public init(origin: DatabaseTransactionOrigin) {
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
/// Prefer ``ValueObservation`` for tracking a query; conform to this protocol when you need the
/// transaction lifecycle itself.
///
/// ```swift
/// final class CommitLogger: DatabaseTransactionObserver {
///   func databaseDidCommit(_ commit: DatabaseCommit) {
///     logger.info("commit from \(String(describing: commit.origin))")
///   }
/// }
///
/// let subscription = try database.subscribe(transactionObserver: CommitLogger())
/// ```
public protocol DatabaseTransactionObserver: Sendable {
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
  func databaseDidCommit(_ commit: DatabaseCommit)

  /// Called after a local transaction rolls back.
  func databaseDidRollback()
}

extension DatabaseTransactionObserver {
  /// Ignores the transaction, letting it commit.
  ///
  /// - Parameter transaction: The committing transaction.
  public func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws {}

  /// Ignores the commit.
  ///
  /// - Parameter commit: The transaction that committed.
  public func databaseDidCommit(_ commit: DatabaseCommit) {}

  /// Ignores the rollback.
  public func databaseDidRollback() {}
}

/// A database whose write transactions can be observed.
///
/// This is what ``ValueObservation`` needs from a database, and what ``OrbitDatabase``
/// provides.
///
/// ```swift
/// let subscription = try database.subscribe(transactionObserver: CommitLogger())
/// ```
public protocol SQLiteObservableDatabase: AnyObject, SQLiteDatabaseWriter {
  /// Registers `transactionObserver` until the returned subscription is cancelled.
  ///
  /// - Parameter transactionObserver: The observer to register.
  /// - Returns: A subscription that unregisters the observer when cancelled or released.
  /// - Throws: An error if the observer cannot be registered.
  func subscribe(
    transactionObserver: any DatabaseTransactionObserver
  ) throws -> OrbitSubscription
}

/// The observers attached to one local database driver.
final class DatabaseTransactionObservers: Sendable {
  private let observers = Lock(IdentifiedRegistry<any DatabaseTransactionObserver>())

  func subscribe(
    _ observer: any DatabaseTransactionObserver
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

  func didCommit(origin: DatabaseTransactionOrigin) {
    let commit = DatabaseCommit(origin: origin)
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
