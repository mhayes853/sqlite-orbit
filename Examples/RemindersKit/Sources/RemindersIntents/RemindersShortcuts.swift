import AppIntents

public struct RemindersShortcuts: AppShortcutsProvider {
  public static var appShortcuts: [AppShortcut] {
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

  public static let shortcutTileColor: ShortcutTileColor = .blue
}
