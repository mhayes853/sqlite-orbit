import AppIntents
import RemindersData
import RemindersIntents
import SQLiteOrbit
import SwiftUI
import WidgetKit

struct RemindersWidgetIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] {
    [RemindersIntentsPackage.self]
  }
}

@main
struct RemindersWidgetBundle: WidgetBundle {
  private let database: RemindersDatabase

  init() {
    let database = try! OrbitIPCDatabase.reminders()
    self.database = database
    RemindersIntentDependencies.register(database: database)
  }

  var body: some Widget {
    RecentRemindersWidget(database: database)
  }
}
