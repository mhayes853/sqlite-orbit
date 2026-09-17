import Observation
import SQLiteOrbit
import SwiftUI

@MainActor
@Observable
final class ReminderCompletionModel {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  var isPending = false

  @ObservationIgnored private let delay: Duration
  @ObservationIgnored private let sleep: Sleep

  init(
    delay: Duration = .seconds(3),
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.delay = delay
    self.sleep = sleep
  }

  func completionStarted() {
    isPending = true
  }

  func completionCancelled() {
    isPending = false
  }

  func finishCompletion(
    _ reminder: Reminder,
    database: RemindersDatabase
  ) async throws {
    defer { isPending = false }
    try await sleep(delay)
    try Task.checkCancellation()
    try await database.write { transaction in
      try Reminder.find(reminder.id)
        .update { $0.status = Reminder.Status.completed }
        .execute(transaction)
    }
  }
}

struct ReminderRow: View {
  let color: Color
  let database: RemindersDatabase
  let isPastDue: Bool
  let notes: String
  let reminder: Reminder
  let remindersList: RemindersList
  let tags: String

  @State private var completionModel = ReminderCompletionModel()
  @State private var completionTask: Task<Void, Never>?
  @State private var errorMessage: String?
  @State private var reminderForm: ReminderFormContext?

  var body: some View {
    let isCompleted = reminder.isCompleted || completionModel.isPending

    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Button(action: completionButtonTapped) {
        Image(systemName: isCompleted ? "circle.inset.filled" : "circle")
          .foregroundStyle(isCompleted ? color : .secondary)
          .font(.title2)
      }
      .accessibilityLabel(isCompleted ? "Mark incomplete" : "Mark complete")

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          if let priority = reminder.priority {
            Text(String(repeating: "!", count: priority.rawValue))
              .foregroundStyle(color)
          }
          Text(reminder.title)
            .foregroundStyle(isCompleted ? .secondary : .primary)
            .strikethrough(isCompleted)
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
      if reminder.isFlagged && !isCompleted {
        Image(systemName: "flag.fill").foregroundStyle(.orange)
      }
      if !isCompleted {
        Button("Details", systemImage: "info.circle", action: detailsButtonTapped)
          .labelStyle(.iconOnly)
          .tint(color)
      }
    }
    .buttonStyle(.borderless)
    .swipeActions {
      Button("Delete", systemImage: "trash", role: .destructive, action: deleteButtonTapped)
      Button(
        reminder.isFlagged ? "Unflag" : "Flag",
        systemImage: "flag",
        action: flagButtonTapped
      )
      .tint(.orange)
      Button("Details", systemImage: "info.circle", action: detailsButtonTapped)
    }
    .sheet(item: $reminderForm) { context in
      NavigationStack {
        ReminderFormView(
          database: database,
          remindersList: remindersList,
          reminder: context.reminder
        )
      }
    }
    .alert(
      "Database Error",
      isPresented: $errorMessage.isPresented
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
  }

  private func completionButtonTapped() {
    completionTask?.cancel()
    if completionModel.isPending {
      withAnimation { completionModel.completionCancelled() }
      completionTask = nil
      return
    }
    guard !reminder.isCompleted else {
      write {
        try Reminder.find(reminder.id)
          .update { $0.toggleCompletion() }
          .execute($0)
      }
      return
    }
    withAnimation { completionModel.completionStarted() }
    completionTask = Task {
      do {
        try await completionModel.finishCompletion(reminder, database: database)
      } catch is CancellationError {
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func deleteButtonTapped() {
    write { try Reminder.delete(reminder).execute($0) }
  }

  private func detailsButtonTapped() {
    reminderForm = ReminderFormContext(remindersList: remindersList, reminder: reminder)
  }

  private func flagButtonTapped() {
    write {
      try Reminder.find(reminder.id)
        .update { $0.isFlagged.toggle() }
        .execute($0)
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
