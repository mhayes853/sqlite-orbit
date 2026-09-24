import AppIntents
import RemindersData
import RemindersNotifications
import SQLiteOrbit
import SwiftUI
import TipKit
import UIKit

@main
struct RemindersApp: App {
  @UIApplicationDelegateAdaptor(RemindersAppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase

  private let database: RemindersDatabase
  private let navigation: RemindersNavigationModel
  private let notificationHandler: ReminderNotificationHandler
  private let notificationScheduler: ReminderNotificationScheduler
  private let root: RemindersRoot
  private let widgetReloader: RemindersWidgetReloader

  init() {
    let database = try! OrbitIPCDatabase.reminders()
    OrbitDefaultDatabase.set(database)
    let widgetReloader = try! RemindersWidgetReloader(database: database)
    database.delegate = widgetReloader
    try? Tips.configure()
    let navigation = RemindersNavigationModel()
    let notificationScheduler = ReminderNotificationScheduler()
    let notificationHandler = ReminderNotificationHandler(
      database: database,
      scheduler: notificationScheduler,
      openReminder: { reminderID in
        await navigation.open(.reminder(reminderID))
      }
    )
    self.database = database
    self.navigation = navigation
    self.notificationHandler = notificationHandler
    self.notificationScheduler = notificationScheduler
    self.widgetReloader = widgetReloader
    root = RemindersRoot(navigation: navigation)
    notificationHandler.register()
    RemindersAppShortcuts.updateAppShortcutParameters()
  }

  var body: some Scene {
    WindowGroup {
      root
        .task(id: scenePhase) {
          guard scenePhase == .active else { return }
          await notificationScheduler.observe(in: database)
        }
    }
  }
}

@MainActor
final class RemindersAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: nil,
      sessionRole: connectingSceneSession.role
    )
    configuration.delegateClass = RemindersSceneDelegate.self
    return configuration
  }
}

@MainActor
final class RemindersSceneDelegate: NSObject, UIWindowSceneDelegate {
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let shortcutItem = connectionOptions.shortcutItem {
      RemindersHomeQuickActions.shared.request(shortcutItem)
    }
  }

  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(RemindersHomeQuickActions.shared.request(shortcutItem))
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
