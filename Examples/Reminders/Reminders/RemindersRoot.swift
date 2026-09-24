import RemindersData
import SQLiteOrbit
import SwiftUI

public struct RemindersRoot: View {
  @State private var navigation: RemindersNavigationModel
  @State private var quickActions = RemindersHomeQuickActions.shared
  @State private var quickActionReminderForm: ReminderFormModel?

  public init() {
    self.init(navigation: RemindersNavigationModel())
  }

  init(navigation: RemindersNavigationModel) {
    _navigation = State(initialValue: navigation)
  }

  public var body: some View {
    @Bindable var navigation = navigation

    NavigationStack(path: $navigation.path) {
      RemindersListsView(navigation: navigation)
        .navigationDestination(for: RemindersDetailModel.self) { model in
          RemindersDetailView(model: model)
        }
    }
    .onOpenURL(perform: open)
    .onChange(of: quickActions.pendingAction) { _, action in
      guard let action else { return }
      quickActions.pendingAction = nil
      Task { await open(action) }
    }
    .task {
      guard let action = quickActions.pendingAction else { return }
      quickActions.pendingAction = nil
      await open(action)
    }
    .sheet(item: $quickActionReminderForm) { formModel in
      NavigationStack {
        ReminderFormView(model: formModel)
      }
    }
    .errorAlert("Could Not Open Link", message: $navigation.errorMessage)
    .fontDesign(.rounded)
  }

  private func open(_ url: URL) {
    guard let route = RemindersRoute(url: url) else { return }
    Task { await navigation.open(route) }
  }

  private func open(_ action: RemindersHomeQuickActions.Action) async {
    do {
      let list = try await OrbitDefaultDatabase.current.read { transaction in
        switch action {
        case .newReminder:
          return try RemindersList.order(by: \.position).fetchOne(transaction)
        case .newInList(let id):
          return try RemindersList.find(id).fetchOne(transaction)
        }
      }
      guard let list else {
        navigation.errorMessage = "Create a list before adding a reminder."
        return
      }
      quickActionReminderForm = ReminderFormModel(remindersList: list)
    } catch {
      navigation.errorMessage = error.localizedDescription
    }
  }
}
