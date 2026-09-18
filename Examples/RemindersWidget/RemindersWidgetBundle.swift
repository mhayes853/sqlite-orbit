import AppIntents
import SwiftUI
import WidgetKit

@main
struct RemindersWidgetBundle: WidgetBundle {
  init() {
    AppDependencyManager.shared.add(
      key: RemindersWidgetDependencyKey.database,
      dependency: RemindersWidgetEnvironment.database
    )
  }

  var body: some Widget {
    RecentRemindersWidget()
  }
}
