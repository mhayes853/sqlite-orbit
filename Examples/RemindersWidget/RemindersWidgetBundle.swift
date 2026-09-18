import AppIntents
import RemindersData
import SQLiteOrbit
import SwiftUI
import WidgetKit

@main
struct RemindersWidgetBundle: WidgetBundle {
  private let database: RemindersDatabase

  init() {
    let database = try! OrbitIPCDatabase.reminders()
    self.database = database
    AppDependencyManager.shared.add(
      key: RemindersWidgetDependencyKey.database,
      dependency: database
    )
  }

  var body: some Widget {
    RecentRemindersWidget(database: database)
  }
}
