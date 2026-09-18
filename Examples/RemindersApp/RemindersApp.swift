import AppIntents
import RemindersData
import RemindersFeature
import SQLiteOrbit
import SwiftUI

@main
struct RemindersApp: App {
  private let root: RemindersRoot

  init() {
    let database = try! OrbitIPCDatabase.reminders()
    RemindersIntentDependencies.register(database: database)
    root = RemindersRoot(database: database)
    RemindersAppShortcuts.updateAppShortcutParameters()
  }

  var body: some Scene {
    WindowGroup {
      root
    }
  }
}

struct RemindersAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CreateReminderIntent(),
      phrases: [
        "Create a reminder with \(.applicationName)",
        "Add a reminder in \(.applicationName)"
      ],
      shortTitle: "New Reminder",
      systemImageName: "plus.circle"
    )
    AppShortcut(
      intent: CompleteReminderIntent(),
      phrases: [
        "Complete \(\.$reminder) in \(.applicationName)",
        "Mark \(\.$reminder) complete in \(.applicationName)"
      ],
      shortTitle: "Complete Reminder",
      systemImageName: "checkmark.circle"
    )
    AppShortcut(
      intent: ReopenReminderIntent(),
      phrases: [
        "Reopen \(\.$reminder) in \(.applicationName)",
        "Mark \(\.$reminder) incomplete in \(.applicationName)"
      ],
      shortTitle: "Reopen Reminder",
      systemImageName: "circle"
    )
  }

  static let shortcutTileColor: ShortcutTileColor = .blue
}
