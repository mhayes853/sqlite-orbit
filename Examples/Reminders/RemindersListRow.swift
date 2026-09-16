import SwiftUI

struct RemindersListRow: View {
  let remindersCount: Int
  let remindersList: RemindersList
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Image(systemName: "list.bullet.circle.fill")
        .font(.largeTitle)
        .foregroundStyle(remindersList.color)
        .background(Color.white.clipShape(Circle()).padding(4))
      Text(remindersList.title)
      Spacer()
      Text(remindersCount, format: .number)
        .foregroundStyle(.secondary)
    }
    .swipeActions {
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
  }
}
