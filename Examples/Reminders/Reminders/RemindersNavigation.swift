import Foundation
import Observation
import RemindersData
import SQLiteOrbit

@MainActor
@Observable
final class RemindersNavigationModel: ErrorReporting {
  var errorMessage: String?
  var path: [RemindersDetailModel] = []
  var reminderForm: ReminderFormModel?

  func detailButtonTapped(_ detailType: RemindersDetailType) {
    path = [RemindersDetailModel(detailType: detailType)]
  }

  func open(_ route: RemindersRoute) async {
    errorMessage = nil
    await withErrorReporting {
      switch route {
      case .list(let id):
        guard
          let list = try await OrbitDefaultDatabase.current.read({
            try RemindersList.find(id).fetchOne($0)
          })
        else { throw RemindersNavigationError.missingList }
        detailButtonTapped(.list(list))

      case .reminder(let id):
        let destination = try await OrbitDefaultDatabase.current.read { transaction in
          guard
            let reminder = try Reminder.find(id).fetchOne(transaction),
            let list = try RemindersList.find(reminder.remindersListID).fetchOne(transaction)
          else { return nil as (Reminder, RemindersList)? }
          return (reminder, list)
        }
        guard let (reminder, list) = destination else {
          throw RemindersNavigationError.missingReminder
        }
        let model = RemindersDetailModel(detailType: .list(list))
        model.reminderForm = ReminderFormModel(remindersList: list, reminder: reminder)
        path = [model]
      }
    }
  }

  func open(_ action: RemindersHomeQuickActions.Action) async {
    errorMessage = nil
    await withErrorReporting {
      let list = try await OrbitDefaultDatabase.current.read { transaction in
        switch action {
        case .newReminder:
          return try RemindersList.order(by: \.position).fetchOne(transaction)
        case .newInList(let id):
          return try RemindersList.find(id).fetchOne(transaction)
        }
      }
      guard let list else {
        switch action {
        case .newReminder:
          errorMessage = "Create a list before adding a reminder."
        case .newInList:
          errorMessage = "This reminders list no longer exists."
        }
        return
      }
      reminderForm = ReminderFormModel(remindersList: list)
    }
  }
}

private enum RemindersNavigationError: LocalizedError {
  case missingList
  case missingReminder

  var errorDescription: String? {
    switch self {
    case .missingList:
      "This reminders list no longer exists."
    case .missingReminder:
      "This reminder no longer exists."
    }
  }
}
