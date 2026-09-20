import RemindersData
import SwiftUI

public struct RemindersRoot: View {
  @State private var navigation: RemindersNavigationModel

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
        .navigationDestination(for: RemindersNavigationModel.Path.self) { path in
          switch path {
          case .detail(let model):
            RemindersDetailView(model: model)
          }
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
