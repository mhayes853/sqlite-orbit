import SQLiteOrbit
import SwiftUI

struct ReminderRow: View {
  let color: Color
  let database: RemindersDatabase
  let isPastDue: Bool
  let notes: String
  let reminder: Reminder
  let remindersList: RemindersList
  let tags: String

  @State private var errorMessage: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Button {
        write {
          try Reminder.find(reminder.id)
            .update { $0.toggleCompletion() }
            .execute($0)
        }
      } label: {
        Image(systemName: reminder.isCompleted ? "circle.inset.filled" : "circle")
          .foregroundStyle(reminder.isCompleted ? color : .secondary)
          .font(.title2)
      }

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          if let priority = reminder.priority {
            Text(String(repeating: "!", count: priority.rawValue))
              .foregroundStyle(color)
          }
          Text(reminder.title)
            .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
            .strikethrough(reminder.isCompleted)
        }
        .font(.title3)

        if !notes.isEmpty {
          Text(notes)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        HStack(spacing: 5) {
          if let dueDate = reminder.dueDate {
            Text(dueDate.formatted(date: .numeric, time: .shortened))
              .foregroundStyle(isPastDue ? .red : .secondary)
          }
          if !tags.isEmpty {
            Text(tags).foregroundStyle(.secondary)
          }
        }
        .font(.callout)
      }

      Spacer()
      if reminder.isFlagged && !reminder.isCompleted {
        Image(systemName: "flag.fill").foregroundStyle(.orange)
      }
    }
    .buttonStyle(.borderless)
    .swipeActions {
      Button("Delete", systemImage: "trash", role: .destructive) {
        write { try Reminder.delete(reminder).execute($0) }
      }
      Button(reminder.isFlagged ? "Unflag" : "Flag", systemImage: "flag") {
        write {
          try Reminder.find(reminder.id)
            .update { $0.isFlagged.toggle() }
            .execute($0)
        }
      }
      .tint(.orange)
    }
    .alert(
      "Database Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
  }

  private func write(
    _ operation: @escaping @Sendable (borrowing SQLiteWriteTransaction) throws -> Void
  ) {
    Task {
      do {
        try await database.write(operation)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
