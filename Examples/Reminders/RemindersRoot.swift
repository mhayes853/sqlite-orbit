import AppIntents
import RemindersData
import RemindersIntents
import SQLiteOrbit
import SwiftUI
import TipKit

public struct RemindersRoot: View {
  private let database: OrbitIPCDatabase
  private let widgetReloader: RemindersWidgetReloader

  public init() {
    self.init(database: try! OrbitIPCDatabase.reminders())
  }

  public init(database: OrbitIPCDatabase) {
    let widgetReloader = try! RemindersWidgetReloader(database: database)
    self.database = database
    self.widgetReloader = widgetReloader
    RemindersIntentDependencies.register(database: database)
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

public struct RemindersFeatureIntentsPackage: AppIntentsPackage {
  public static var includedPackages: [any AppIntentsPackage.Type] {
    [RemindersIntentsPackage.self]
  }
}
