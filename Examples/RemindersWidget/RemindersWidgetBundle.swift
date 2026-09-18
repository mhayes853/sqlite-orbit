import AppIntents
import RemindersData
import SwiftUI
import WidgetKit

@main
struct RemindersWidgetBundle: WidgetBundle {
  init() {
    AppDependencyManager.shared.add(
      key: RemindersWidgetDependencyKey.database,
      dependency: RemindersEnvironment.database
    )
  }

  var body: some Widget {
    RecentRemindersWidget()
  }
}
