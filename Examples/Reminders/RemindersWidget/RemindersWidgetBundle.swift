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
  init() {
    OrbitDefaultDatabase.set(try! OrbitIPCDatabase.reminders())
  }

  var body: some Widget {
    RecentRemindersWidget()
  }
}
