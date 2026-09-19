import RemindersData
import SQLiteOrbit
import WidgetKit

final class RemindersWidgetReloader: OrbitIPCDatabase.Delegate, Sendable {
  private let observedRegion: OrbitDatabaseRegion

  init(database: OrbitIPCDatabase) throws {
    observedRegion = try database.readBlocking { transaction in
      try OrbitDatabaseRegion(
        WidgetReminder.recent(
          limit: RemindersWidgetConfiguration.maximumReminderCount
        ).query,
        in: transaction
      )
    }
  }

  func orbitIPCDatabase(
    _ database: OrbitIPCDatabase,
    willAnnounce message: OrbitIPCMessage
  ) {
    guard
      case .transactionDidCommit(let commit) = message,
      commit.region.overlaps(observedRegion)
    else { return }

    WidgetCenter.shared.reloadTimelines(ofKind: RemindersWidgetConfiguration.kind)
  }
}
