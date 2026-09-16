import SQLiteOrbit
import SwiftUI
import TipKit

public struct RemindersRoot: View {
  private let database: OrbitIPCDatabase

  public init() {
    database = try! makeAppDatabase()
    try? Tips.configure()
  }

  public var body: some View {
    NavigationStack {
      RemindersListsView(database: database)
    }
    .orbitDatabase(database)
  }
}

struct RemindersListsView: View {
  @FetchAll var remindersLists: [RemindersList]

  init(database: any OrbitObservableDatabase) {
    _remindersLists = FetchAll(
      RemindersList.order(by: \.position),
      database: database,
      animation: .default
    )
  }

  var body: some View {
    List(remindersLists) { remindersList in
      Label(remindersList.title, systemImage: "list.bullet.circle.fill")
        .foregroundStyle(remindersList.color)
    }
    .navigationTitle("Reminders")
    .overlay {
      if remindersLists.isEmpty {
        ContentUnavailableView(
          "No Lists",
          systemImage: "checklist",
          description: Text("The database is ready for its first reminders list.")
        )
      }
    }
  }
}
