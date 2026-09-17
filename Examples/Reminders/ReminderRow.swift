import Observation
import SQLiteOrbit
import SwiftUI

@MainActor
@Observable
final class ReminderRowModel {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  var errorMessage: String?
  var isCompletionPending = false
  var reminderForm: ReminderFormContext?

  @ObservationIgnored private let database: RemindersDatabase
  @ObservationIgnored private let delay: Duration
  @ObservationIgnored private let sleep: Sleep
  @ObservationIgnored private var completionGeneration = 0
  @ObservationIgnored private var completionTask: Task<Void, Never>?

  init(
    database: RemindersDatabase,
    delay: Duration = .seconds(3),
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.database = database
    self.delay = delay
    self.sleep = sleep
  }

  func isCompleted(_ reminder: Reminder) -> Bool {
    reminder.isCompleted || isCompletionPending
  }

  @discardableResult
  func completionButtonTapped(_ reminder: Reminder) -> Task<Void, Never>? {
    completionGeneration += 1
    let generation = completionGeneration
    completionTask?.cancel()
    if isCompletionPending {
      withAnimation { isCompletionPending = false }
      completionTask = nil
      return nil
    }
    guard !reminder.isCompleted else {
      return write {
        try Reminder.find(reminder.id)
          .update { $0.toggleCompletion() }
          .execute($0)
      }
    }
    withAnimation { isCompletionPending = true }
    completionTask = Task { [weak self] in
      guard let self else { return }
      await finishCompletion(reminder, generation: generation)
    }
    return completionTask
  }

  @discardableResult
  func deleteButtonTapped(_ reminder: Reminder) -> Task<Void, Never> {
    write { try Reminder.delete(reminder).execute($0) }
  }

  func detailsButtonTapped(
    _ reminder: Reminder,
    remindersList: RemindersList
  ) {
    reminderForm = ReminderFormContext(remindersList: remindersList, reminder: reminder)
  }

  @discardableResult
  func flagButtonTapped(_ reminder: Reminder) -> Task<Void, Never> {
    write {
      try Reminder.find(reminder.id)
        .update { $0.isFlagged.toggle() }
        .execute($0)
    }
  }

  private func finishCompletion(_ reminder: Reminder, generation: Int) async {
    defer {
      if completionGeneration == generation {
        withAnimation { isCompletionPending = false }
        completionTask = nil
      }
    }
    do {
      try await sleep(delay)
      try Task.checkCancellation()
      try await database.write { transaction in
        try Reminder.find(reminder.id)
          .update { $0.status = Reminder.Status.completed }
          .execute(transaction)
      }
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func write(
    _ operation: @escaping @Sendable (borrowing SQLiteWriteTransaction) throws -> Void
  ) -> Task<Void, Never> {
    Task {
      do {
        try await database.write(operation)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  fileprivate var databaseForView: RemindersDatabase { database }
}

struct ReminderRow: View {
  let color: Color
  let isPastDue: Bool
  let notes: String
  let reminder: Reminder
  let remindersList: RemindersList
  let tags: String

  @State private var model: ReminderRowModel

  init(
    color: Color,
    database: RemindersDatabase,
    isPastDue: Bool,
    notes: String,
    reminder: Reminder,
    remindersList: RemindersList,
    tags: String
  ) {
    self.color = color
    self.isPastDue = isPastDue
    self.notes = notes
    self.reminder = reminder
    self.remindersList = remindersList
    self.tags = tags
    _model = State(initialValue: ReminderRowModel(database: database))
  }

  var body: some View {
    @Bindable var model = model
    let isCompleted = model.isCompleted(reminder)

    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Button {
        model.completionButtonTapped(reminder)
      } label: {
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
        Button("Details", systemImage: "info.circle") {
          model.detailsButtonTapped(reminder, remindersList: remindersList)
        }
        .labelStyle(.iconOnly)
        .tint(color)
      }
    }
    .buttonStyle(.borderless)
    .swipeActions {
      Button("Delete", systemImage: "trash", role: .destructive) {
        model.deleteButtonTapped(reminder)
      }
      Button(
        reminder.isFlagged ? "Unflag" : "Flag",
        systemImage: "flag"
      ) {
        model.flagButtonTapped(reminder)
      }
      .tint(.orange)
      Button("Details", systemImage: "info.circle") {
        model.detailsButtonTapped(reminder, remindersList: remindersList)
      }
    }
    .sheet(item: $model.reminderForm) { context in
      NavigationStack {
        ReminderFormView(
          database: model.databaseForView,
          remindersList: remindersList,
          reminder: context.reminder
        )
      }
    }
    .alert(
      "Database Error",
      isPresented: $model.errorMessage.isPresented
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }
}
