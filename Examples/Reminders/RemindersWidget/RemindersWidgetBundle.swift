import RemindersData
import SQLiteOrbit
import SwiftUI
import WidgetKit

@main
struct RemindersWidgetBundle: WidgetBundle {
  init() {
    OrbitDefaultDatabase.set(try! OrbitIPCDatabase.reminders())
  }

  var body: some Widget {
    RecentRemindersWidget()
  }
}
