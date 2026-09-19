import RemindersData
import SQLiteOrbit
import SwiftUI
import TipKit

public struct RemindersRoot: View {
  private let widgetReloader: RemindersWidgetReloader

  public init() {
    self.init(database: try! OrbitIPCDatabase.reminders())
  }

  public init(database: OrbitIPCDatabase) {
    let widgetReloader = try! RemindersWidgetReloader(database: database)
    self.widgetReloader = widgetReloader
    database.delegate = widgetReloader
    OrbitDefaultDatabase.set(database)
    try? Tips.configure()
  }

  public var body: some View {
    NavigationStack {
      RemindersListsView()
    }
    .fontDesign(.rounded)
  }
}
