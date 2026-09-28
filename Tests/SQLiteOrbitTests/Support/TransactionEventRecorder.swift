import StructuredQueries

@testable import SQLiteOrbit

/// A transaction observer that records everything it is told, in order.
///
/// ```swift
/// let recorder = TransactionEventRecorder(
///   countOnWillCommit: #sql("SELECT count(*) FROM items", as: Int.self)
/// )
/// let subscription = try database.subscribe(transactionObserver: recorder)
/// try await database.write { try $0.execute("INSERT INTO items (id) VALUES (1)") }
/// #expect(recorder.events == [.didChange(items), .willCommit(1), .didCommit(.local)])
/// ```
final class TransactionEventRecorder: OrbitDatabaseTransactionObserver, Sendable {
  /// Something the observer was told.
  enum Event: Equatable, Sendable {
    case didChange(OrbitDatabaseRegion)
    /// What the recorder's query counted, just before the commit.
    case willCommit(Int)
    case didCommit(OrbitDatabaseTransactionOrigin)
    case didRollback
  }

  private struct State {
    var events = [Event]()
    var commits = [OrbitDatabaseCommit]()
    var readRegions = [OrbitDatabaseRegion]()
  }

  private let state = Lock(State())
  private let countOnWillCommit: SQLQueryExpression<Int>?

  /// Makes a recorder.
  ///
  /// - Parameter countOnWillCommit: A query each committing transaction runs, whose result is
  ///   recorded as ``Event/willCommit(_:)``, so the recorder sees what the transaction is about
  ///   to commit. Without one, the recorder records no ``Event/willCommit(_:)``.
  init(countOnWillCommit: SQLQueryExpression<Int>? = nil) {
    self.countOnWillCommit = countOnWillCommit
  }

  /// Every change, commit and rollback, in the order they came.
  var events: [Event] { self.state.withLock { $0.events } }

  /// Every commit.
  var commits: [OrbitDatabaseCommit] { self.state.withLock { $0.commits } }

  /// The region of every change.
  var changedRegions: [OrbitDatabaseRegion] {
    self.events.compactMap {
      guard case .didChange(let region) = $0 else { return nil }
      return region
    }
  }

  /// The region of every read.
  var readRegions: [OrbitDatabaseRegion] { self.state.withLock { $0.readRegions } }

  /// Forgets everything recorded so far.
  func removeAll() {
    self.state.withLock { $0 = State() }
  }

  /// Waits until at least `count` commits have been recorded.
  ///
  /// - Throws: ``TestTimeout`` once `timeout` passes first.
  func waitForCommitCount(_ count: Int, timeout: Duration = .seconds(5)) async throws {
    try await waitUntil(timeout: timeout) { self.commits.count >= count }
  }

  func databaseDidRead(in region: OrbitDatabaseRegion) {
    self.state.withLock { $0.readRegions.append(region) }
  }

  func databaseDidChange(in region: OrbitDatabaseRegion) {
    self.state.withLock { $0.events.append(.didChange(region)) }
  }

  func databaseWillCommit(_ transaction: borrowing SQLiteReadTransaction) throws {
    guard let query = self.countOnWillCommit else { return }
    let count = try transaction.fetchOne(query) ?? 0
    self.state.withLock { $0.events.append(.willCommit(count)) }
  }

  func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    self.state.withLock { state in
      state.events.append(.didCommit(commit.origin))
      state.commits.append(commit)
    }
  }

  func databaseDidRollback() {
    self.state.withLock { $0.events.append(.didRollback) }
  }
}
