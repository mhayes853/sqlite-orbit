import RemindersData
import SQLiteOrbit
import WidgetKit

final class RemindersWidgetReloader: OrbitIPCDatabase.Delegate, Sendable {
  private let observedRegion: OrbitDatabaseRegion

  init(database: OrbitIPCDatabase) throws {
    observedRegion = try RemindersWidgetStore(database: database).observedRegion(
      limit: RemindersWidgetConfiguration.maximumReminderCount
    )
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
