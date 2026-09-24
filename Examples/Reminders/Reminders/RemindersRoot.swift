import Observation
import RemindersData
import SwiftUI
import UIKit

public struct RemindersRoot: View {
  @State private var navigation: RemindersNavigationModel
  let quickActions: RemindersHomeQuickActions

  public init() {
    self.init(
      navigation: RemindersNavigationModel(),
      quickActions: RemindersHomeQuickActions()
    )
  }

  init(navigation: RemindersNavigationModel, quickActions: RemindersHomeQuickActions) {
    _navigation = State(initialValue: navigation)
    self.quickActions = quickActions
  }

  public var body: some View {
    @Bindable var navigation = navigation

    NavigationStack(path: $navigation.path) {
      RemindersListsView(navigation: navigation, quickActions: quickActions)
        .navigationDestination(for: RemindersDetailModel.self) { model in
          RemindersDetailView(model: model)
        }
    }
    .onOpenURL(perform: open)
    .onChange(of: quickActions.pendingAction, initial: true) { _, action in
      guard let action else { return }
      quickActions.pendingAction = nil
      Task { await navigation.open(action) }
    }
    .sheet(item: $navigation.reminderForm) { formModel in
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
}

@MainActor
@Observable
final class RemindersHomeQuickActions {
  private static let newReminderType = "co.sqlite-orbit.Reminders.newReminder"
  private static let newInListType = "co.sqlite-orbit.Reminders.newInList"
  private static let listIDKey = "listID"

  enum Action: Equatable {
    case newReminder
    case newInList(RemindersList.ID)
  }

  var pendingAction: Action?

  @discardableResult
  func request(_ item: UIApplicationShortcutItem) -> Bool {
    switch item.type {
    case Self.newReminderType:
      pendingAction = .newReminder
    case Self.newInListType:
      guard
        let idString = item.userInfo?[Self.listIDKey] as? String,
        let id = RemindersList.ID(uuidString: idString)
      else { return false }
      pendingAction = .newInList(id)
    default:
      return false
    }
    return true
  }

  func update(for lists: [RemindersList]) {
    UIApplication.shared.shortcutItems = lists.prefix(3).map { list in
      UIApplicationShortcutItem(
        type: Self.newInListType,
        localizedTitle: "New in \(list.title)",
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(systemImageName: "plus"),
        userInfo: [Self.listIDKey: list.id.uuidString as NSString]
      )
    }
  }
}
