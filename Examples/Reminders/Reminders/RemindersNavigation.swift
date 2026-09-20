import Foundation
import Observation
import RemindersData
import SQLiteOrbit

@MainActor
@Observable
final class RemindersNavigationModel: ErrorReporting {
  var errorMessage: String?
  var path: [RemindersDetailType] = []
  var reminderForm: ReminderFormContext?

  func show(_ detailType: RemindersDetailType) {
    reminderForm = nil
    path = [detailType]
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
        show(.list(list))

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
        path = [.list(list)]
        reminderForm = ReminderFormContext(remindersList: list, reminder: reminder)
      }
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
