/// Connection-local event routing, confined to one serialized SQLite access.
///
/// Registrations nest in call order, so an outer registration receives each event first.
final class SQLiteConnectionEvents {
  private var observers: [any OrbitDatabaseTransactionObserver] = []
  private var pendingRegion = OrbitDatabaseRegion.empty

  init() {}

  func withObservation<Result: ~Copyable>(
    _ observer: any OrbitDatabaseTransactionObserver,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    observers.append(observer)
    defer { observers.removeLast() }
    return try operation()
  }

  func didRead(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    for observer in observers { observer.databaseDidRead(in: region) }
  }

  func didChange(in region: OrbitDatabaseRegion) {
    guard !region.isEmpty else { return }
    pendingRegion.formUnion(region)
    for observer in observers { observer.databaseDidChange(in: region) }
  }

  func willCommit(_ transaction: borrowing SQLiteReadTransaction) throws {
    for observer in observers { try observer.databaseWillCommit(transaction) }
  }

  func didCommit() {
    let region = pendingRegion
    pendingRegion = .empty
    let commit = OrbitDatabaseCommit(origin: .local, region: region)
    for observer in observers { observer.databaseDidCommit(commit) }
  }

  func didRollback() {
    pendingRegion = .empty
    for observer in observers { observer.databaseDidRollback() }
  }

  /// Outside a transaction SQLite commits as a statement finishes. Report even a statement that
  /// fails after publishing changes conservatively, so observers cannot miss a committed change.
  func didCommitPendingChanges() {
    guard !pendingRegion.isEmpty else { return }
    didCommit()
  }
}
