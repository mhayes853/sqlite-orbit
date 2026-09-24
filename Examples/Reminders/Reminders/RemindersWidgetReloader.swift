import RemindersData
import SQLiteOrbit
import WidgetKit

final class RemindersWidgetReloader: OrbitIPCDatabase.Delegate, Sendable {
  private let observedRegion: OrbitDatabaseRegion
  private let refresh: @Sendable () -> Void
  private let externalObserver: ExternalWidgetCommitObserver
  private let subscription: OrbitSubscription

  init(
    database: OrbitIPCDatabase,
    refresh: @escaping @Sendable () -> Void = {
      WidgetCenter.shared.reloadTimelines(ofKind: RemindersWidgetConfiguration.kind)
    }
  ) throws {
    let region = try database.readBlocking { transaction in
      try OrbitDatabaseRegion(
        WidgetReminder.recent(
          limit: RemindersWidgetConfiguration.maximumReminderCount
        ).query,
        in: transaction
      )
    }
    observedRegion = region
    self.refresh = refresh
    externalObserver = ExternalWidgetCommitObserver(region: region, refresh: refresh)
    subscription = try database.subscribe(transactionObserver: externalObserver)
  }

  func orbitIPCDatabase(
    _ database: OrbitIPCDatabase,
    didSuccessfullyAnnounce message: OrbitIPCMessage
  ) {
    guard
      case .transactionDidCommit(let commit) = message,
      commit.region.overlaps(observedRegion)
    else { return }

    refresh()
  }
}

private final class ExternalWidgetCommitObserver: OrbitDatabaseTransactionObserver, Sendable {
  let region: OrbitDatabaseRegion
  let refresh: @Sendable () -> Void

  init(region: OrbitDatabaseRegion, refresh: @escaping @Sendable () -> Void) {
    self.region = region
    self.refresh = refresh
  }

  func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    guard commit.origin == .external, commit.region.overlaps(region) else { return }
    refresh()
  }
}
