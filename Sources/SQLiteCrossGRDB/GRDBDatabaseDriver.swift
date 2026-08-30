#if SQLiteCrossGRDB
  import Foundation
  import GRDB
  import SQLiteCross

  /// A ``LocalDatabaseDriver`` backed by a GRDB database writer.
  public final class GRDBDatabaseDriver: LocalDatabaseDriver, Sendable {
    public let identifier: DatabaseIdentifier
    public let writer: any DatabaseWriter

    private let state = GRDBDatabaseDriverState()

    public init(identifier: DatabaseIdentifier, writer: any DatabaseWriter) {
      self.identifier = identifier
      self.writer = writer
    }

    public func subscribeToLocalCommits(
      _ onCommit: @escaping @Sendable (DatabaseChangeRegion) -> Void
    ) throws -> any TransactionSubscription {
      let observer = GRDBCommitObserver(state: state, onCommit: onCommit)
      writer.add(transactionObserver: observer, extent: .observerLifetime)
      return GRDBTransactionSubscription(observer: observer)
    }

    public func notifyChangesFromExternalCommit(in region: DatabaseChangeRegion) async throws {
      try await writer.write { [state] database in
        try state.withExternalNotification {
          switch region {
          case .fullDatabase:
            try database.notifyChanges(in: .fullDatabase)
          case .tables(let tableNames):
            for tableName in tableNames {
              try database.notifyChanges(in: Table(tableName))
            }
          }
        }
      }
    }
  }

  private final class GRDBDatabaseDriverState: @unchecked Sendable {
    private let lock = NSLock()
    private var externalNotificationDepth = 0

    var isApplyingExternalNotification: Bool {
      lock.withLock { externalNotificationDepth > 0 }
    }

    func withExternalNotification<Result>(_ operation: () throws -> Result) rethrows -> Result {
      lock.withLock {
        externalNotificationDepth += 1
      }
      defer {
        lock.withLock {
          externalNotificationDepth -= 1
        }
      }
      return try operation()
    }
  }

  private final class GRDBCommitObserver: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private let state: GRDBDatabaseDriverState
    private let onCommit: @Sendable (DatabaseChangeRegion) -> Void
    private var isActive = true
    private var isSuppressed = false
    private var changedRegion: DatabaseChangeRegion?

    init(
      state: GRDBDatabaseDriverState,
      onCommit: @escaping @Sendable (DatabaseChangeRegion) -> Void
    ) {
      self.state = state
      self.onCommit = onCommit
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
      true
    }

    func databaseDidChange() {
      recordChange(in: .fullDatabase)
    }

    func databaseDidChange(with event: DatabaseEvent) {
      recordChange(in: .tables([event.tableName]))
    }

    func databaseWillCommit() throws {}

    func databaseDidCommit(_ database: Database) {
      let region = lock.withLock { () -> DatabaseChangeRegion? in
        defer { resetTransaction() }
        guard isActive, !isSuppressed else { return nil }
        return changedRegion
      }
      if let region {
        onCommit(region)
      }
    }

    func databaseDidRollback(_ database: Database) {
      lock.withLock {
        resetTransaction()
      }
    }

    func cancel() {
      lock.withLock {
        isActive = false
        resetTransaction()
      }
    }

    private func recordChange(in region: DatabaseChangeRegion) {
      let isExternal = state.isApplyingExternalNotification
      lock.withLock {
        guard isActive else { return }
        isSuppressed = isSuppressed || isExternal
        changedRegion = changedRegion.map { $0.union(region) } ?? region
      }
    }

    private func resetTransaction() {
      isSuppressed = false
      changedRegion = nil
    }
  }

  private final class GRDBTransactionSubscription: TransactionSubscription, @unchecked Sendable {
    private let lock = NSLock()
    private var observer: GRDBCommitObserver?

    init(observer: GRDBCommitObserver) {
      self.observer = observer
    }

    func cancel() {
      let observer = lock.withLock {
        defer { self.observer = nil }
        return self.observer
      }
      observer?.cancel()
    }

    deinit {
      cancel()
    }
  }
#endif
