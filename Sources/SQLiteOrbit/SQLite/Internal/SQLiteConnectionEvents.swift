/// Connection-local event routing, confined to one serialized SQLite access.
///
/// Registrations nest in call order, so an outer registration receives each event first.
final class SQLiteConnectionEvents {
  private var observers: [any SQLiteConnectionObserver] = []
  private var pendingRegion = OrbitDatabaseRegion.empty

  init() {}

  func withObservation<Result: ~Copyable>(
    _ observer: any SQLiteConnectionObserver,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    observers.append(observer)
    defer { observers.removeLast() }
    return try operation()
  }

  func didRead(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    for observer in observers { observer.connectionDidRead(in: region) }
  }

  func didChange(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    pendingRegion.formUnion(region)
    for observer in observers { observer.connectionDidChange(in: region) }
  }

  func willCommit(_ transaction: borrowing SQLiteReadTransaction) throws {
    for observer in observers { try observer.connectionWillCommit(transaction) }
  }

  func didCommit() {
    let region = pendingRegion
    pendingRegion = .empty
    for observer in observers { observer.connectionDidCommit(in: region) }
  }

  func didRollback() {
    pendingRegion = .empty
    for observer in observers { observer.connectionDidRollback() }
  }

  /// Outside a transaction SQLite commits as a statement finishes. Report even a statement that
  /// fails after publishing changes conservatively, so observers cannot miss a committed change.
  func didCommitPendingChanges() {
    guard !pendingRegion.isEmpty else { return }
    didCommit()
  }
}
