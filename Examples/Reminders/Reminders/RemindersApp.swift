import AppIntents
import RemindersData
import RemindersIntents
import RemindersNotifications
import SQLiteOrbit
import SwiftUI

struct RemindersAppIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] {
    [RemindersIntentsPackage.self]
  }
}

@main
struct RemindersApp: App {
  @Environment(\.scenePhase) private var scenePhase

  private let notificationHandler: ReminderNotificationHandler
  private let notificationObservation: ReminderNotificationObservation
  private let root: RemindersRoot

  init() {
    let database = try! OrbitIPCDatabase.reminders()
    OrbitDefaultDatabase.set(database)
    let notificationScheduler = ReminderNotificationScheduler()
    let notificationHandler = ReminderNotificationHandler(
      database: database,
      scheduler: notificationScheduler
    )
    self.notificationHandler = notificationHandler
    notificationObservation = ReminderNotificationObservation(
      database: database,
      scheduler: notificationScheduler
    )
    root = RemindersRoot(database: database)
    notificationHandler.register()
    RemindersAppShortcuts.updateAppShortcutParameters()
  }

  var body: some Scene {
    WindowGroup {
      root
        .task(id: scenePhase) {
          guard scenePhase == .active else { return }
          await notificationObservation.reconcile()
        }
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
