/// Where a committed database transaction was performed.
public enum DatabaseTransactionOrigin: Hashable, Sendable {
  /// The transaction was performed by a database handle in this process.
  case local

  /// The transaction was announced by another process.
  case external
}

/// A successfully committed database transaction.
public struct DatabaseCommit: Hashable, Sendable {
  public let origin: DatabaseTransactionOrigin

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
public protocol DatabaseTransactionObserver: Sendable {
  /// Called before a local transaction commits.
  ///
  /// The transaction exposes the read capability, so its structured-query APIs can inspect the
  /// final transaction state but cannot mutate it. Throwing aborts the write transaction.
  func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws

  /// Called after a transaction commits.
  func databaseDidCommit(_ commit: DatabaseCommit)

  /// Called after a local transaction rolls back.
  func databaseDidRollback()
}

extension DatabaseTransactionObserver {
  public func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws {}

  public func databaseDidCommit(_ commit: DatabaseCommit) {}

  public func databaseDidRollback() {}
}

/// A database whose write transactions can be observed.
public protocol SQLiteObservableDatabase: AnyObject, SQLiteDatabaseWriter {
  /// Registers `transactionObserver` until the returned subscription is cancelled.
  func subscribe(
    transactionObserver: any DatabaseTransactionObserver
  ) throws -> OrbitSubscription
}

/// The observers attached to one local database driver.
final class DatabaseTransactionObservers: Sendable {
  private struct State: Sendable {
    var nextIdentifier: UInt64 = 0
    var observers = [UInt64: any DatabaseTransactionObserver]()
  }

  private let state = Lock(State())

  func subscribe(
    _ observer: any DatabaseTransactionObserver
  ) -> OrbitSubscription {
    let identifier = state.withLock { state in
      let identifier = state.nextIdentifier
      state.nextIdentifier &+= 1
      state.observers[identifier] = observer
      return identifier
    }
    return OrbitSubscription { [weak self] in
      _ = self?.state
        .withLock { state in
          state.observers.removeValue(forKey: identifier)
        }
    }
  }

  func willCommit(_ transaction: borrowing SQLiteReadTransaction) throws {
    let observers = state.withLock { Array($0.observers.values) }
    for observer in observers {
      try observer.databaseWillCommit(transaction)
    }
  }

  func didCommit(origin: DatabaseTransactionOrigin) {
    let observers = state.withLock { Array($0.observers.values) }
    let commit = DatabaseCommit(origin: origin)
    for observer in observers {
      observer.databaseDidCommit(commit)
    }
  }

  func didRollback() {
    let observers = state.withLock { Array($0.observers.values) }
    for observer in observers {
      observer.databaseDidRollback()
    }
  }
}
