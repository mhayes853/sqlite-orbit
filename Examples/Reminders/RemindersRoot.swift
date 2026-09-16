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
