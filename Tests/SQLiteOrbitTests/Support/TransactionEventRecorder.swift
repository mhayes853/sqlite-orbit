@testable import SQLiteOrbit

/// A transaction observer that records everything it is told, in order.
///
/// ```swift
/// let recorder = TransactionEventRecorder(
///   countOnWillCommit: "SELECT count(*) FROM items"
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
  private let countOnWillCommit: SQL?
  private let commitError: (any Error)?

  /// Makes a recorder.
  ///
  /// - Parameters:
  ///   - countOnWillCommit: A query each committing transaction runs, whose result is recorded
  ///     as ``Event/willCommit(_:)``. Without one, no will-commit event is recorded.
  ///   - commitError: An error thrown to reject commit, after recording any requested count.
  init(countOnWillCommit: SQL? = nil, commitError: (any Error)? = nil) {
    self.countOnWillCommit = countOnWillCommit
    self.commitError = commitError
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
    if let query = self.countOnWillCommit {
      let count = try transaction.fetchOne(query) { Int($0[0].integerValue ?? 0) } ?? 0
      self.state.withLock { $0.events.append(.willCommit(count)) }
    }
    if let commitError { throw commitError }
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
