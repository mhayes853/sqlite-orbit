import RemindersData
import SwiftUI

struct RemindersListRow: View {
  let remindersCount: Int
  let remindersList: RemindersList
  let onDelete: () -> Void
  let onEdit: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      RemindersListIcon(color: remindersList.color)
      Text(remindersList.title)
        .font(.body)
      Spacer()
      Text(remindersCount, format: .number)
        .foregroundStyle(.secondary)
    }
    .frame(minHeight: 48)
    .accessibilityElement(children: .combine)
    .swipeActions {
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
      Button("Details", systemImage: "info.circle", action: onEdit)
        .tint(.blue)
    }
  }
}
