import RemindersData
import SQLiteOrbit
import SwiftUI
import TipKit

public struct RemindersRoot: View {
  private let database: OrbitIPCDatabase
  private let widgetReloader: RemindersWidgetReloader

  public init() {
    let database = try! OrbitIPCDatabase.reminders()
    let widgetReloader = try! RemindersWidgetReloader(database: database)
    self.database = database
    self.widgetReloader = widgetReloader
    database.delegate = widgetReloader
    try? Tips.configure()
  }

  public var body: some View {
    NavigationStack {
      RemindersListsView(database: database)
    }
    .fontDesign(.rounded)
    .orbitDatabase(database)
  }
}
