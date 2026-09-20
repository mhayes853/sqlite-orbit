import RemindersData
import SQLiteOrbit
import SwiftUI
import TipKit

public struct RemindersRoot: View {
  @State private var navigation: RemindersNavigationModel
  private let widgetReloader: RemindersWidgetReloader

  public init() {
    self.init(database: try! OrbitIPCDatabase.reminders())
  }

  public init(database: OrbitIPCDatabase) {
    self.init(database: database, navigation: RemindersNavigationModel())
  }

  init(
    database: OrbitIPCDatabase,
    navigation: RemindersNavigationModel
  ) {
    _navigation = State(initialValue: navigation)
    let widgetReloader = try! RemindersWidgetReloader(database: database)
    self.widgetReloader = widgetReloader
    database.delegate = widgetReloader
    OrbitDefaultDatabase.set(database)
    try? Tips.configure()
  }

  public var body: some View {
    @Bindable var navigation = navigation

    NavigationStack(path: $navigation.path) {
      RemindersListsView(navigation: navigation)
        .navigationDestination(for: RemindersDetailType.self) { detailType in
          RemindersDetailView(model: RemindersDetailModel(detailType: detailType))
        }
    }
    .sheet(item: $navigation.reminderForm) { context in
      NavigationStack {
        ReminderFormView(
          remindersList: context.remindersList,
          reminder: context.reminder
        )
      }
    }
    .onOpenURL(perform: open)
    .errorAlert("Could Not Open Link", message: $navigation.errorMessage)
    .fontDesign(.rounded)
  }

  private func open(_ url: URL) {
    guard let route = RemindersRoute(url: url) else { return }
    Task { await navigation.open(route) }
  }
}
