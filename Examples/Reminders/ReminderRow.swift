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
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let delay: Duration
  @ObservationIgnored private let now: Date
  @ObservationIgnored private let sleep: Sleep
  @ObservationIgnored private var completionGeneration = 0
  @ObservationIgnored private var completionTask: Task<Void, Never>?

  init(
    database: RemindersDatabase,
    calendar: Calendar = .current,
    delay: Duration = .seconds(3),
    now: Date = .now,
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.database = database
    self.calendar = calendar
    self.delay = delay
    self.now = now
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

  @discardableResult
  func dueDateButtonTapped(
    _ reminder: Reminder,
    daysFromToday: Int
  ) -> Task<Void, Never> {
    let dueDate = calendar.date(
      byAdding: .day,
      value: daysFromToday,
      to: calendar.startOfDay(for: now)
    )
    return write {
      try Reminder.find(reminder.id)
        .update { $0.dueDate = dueDate }
        .execute($0)
    }
  }

  @discardableResult
  func clearDueDateButtonTapped(_ reminder: Reminder) -> Task<Void, Never> {
    write {
      try Reminder.find(reminder.id)
        .update { $0.dueDate = #bind(nil as Date?) }
        .execute($0)
    }
  }

  @discardableResult
  func moveToListButtonTapped(
    _ reminder: Reminder,
    remindersList: RemindersList
  ) -> Task<Void, Never> {
    write {
      try Reminder.find(reminder.id)
        .update { $0.remindersListID = remindersList.id }
        .execute($0)
    }
  }

  @discardableResult
  func priorityButtonTapped(
    _ reminder: Reminder,
    priority: Reminder.Priority?
  ) -> Task<Void, Never> {
    write {
      try Reminder.find(reminder.id)
        .update { $0.priority = priority }
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
  let remindersLists: [RemindersList]
  let tags: String

  @State private var model: ReminderRowModel

  init(
    color: Color,
    database: RemindersDatabase,
    isPastDue: Bool,
    notes: String,
    reminder: Reminder,
    remindersList: RemindersList,
    remindersLists: [RemindersList],
    tags: String
  ) {
    self.color = color
    self.isPastDue = isPastDue
    self.notes = notes
    self.reminder = reminder
    self.remindersList = remindersList
    self.remindersLists = remindersLists
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
    .contextMenu {
      ReminderContextMenu(
        model: model,
        reminder: reminder,
        remindersList: remindersList,
        remindersLists: remindersLists
      )
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

private struct ReminderContextMenu: View {
  let model: ReminderRowModel
  let reminder: Reminder
  let remindersList: RemindersList
  let remindersLists: [RemindersList]

  var body: some View {
    ControlGroup {
      Button("Details", systemImage: "info.circle") {
        model.detailsButtonTapped(reminder, remindersList: remindersList)
      }
      Button("Delete", systemImage: "trash", role: .destructive) {
        model.deleteButtonTapped(reminder)
      }
    }

    Divider()

    Button(
      model.isCompleted(reminder) ? "Mark as Incomplete" : "Mark as Completed",
      systemImage: model.isCompleted(reminder) ? "circle" : "circle.inset.filled"
    ) {
      model.completionButtonTapped(reminder)
    }

    Menu("Due Date", systemImage: "calendar") {
      Button("Today", systemImage: "sun.max") {
        model.dueDateButtonTapped(reminder, daysFromToday: 0)
      }
      Button("Tomorrow", systemImage: "sunrise") {
        model.dueDateButtonTapped(reminder, daysFromToday: 1)
      }
      if reminder.dueDate != nil {
        Divider()
        Button("Clear", systemImage: "calendar.badge.minus") {
          model.clearDueDateButtonTapped(reminder)
        }
      }
    }

    Menu("Move to List", systemImage: "list.bullet") {
      ForEach(remindersLists) { list in
        Button {
          model.moveToListButtonTapped(reminder, remindersList: list)
        } label: {
          if list.id == reminder.remindersListID {
            Label(list.title, systemImage: "checkmark")
          } else {
            Text(list.title)
          }
        }
        .disabled(list.id == reminder.remindersListID)
      }
    }

    Menu("Priority", systemImage: "exclamationmark") {
      priorityButton("None", priority: nil)
      priorityButton("Low", priority: .low)
      priorityButton("Medium", priority: .medium)
      priorityButton("High", priority: .high)
    }

    Divider()

    Button(
      reminder.isFlagged ? "Unflag" : "Flag",
      systemImage: reminder.isFlagged ? "flag.slash" : "flag"
    ) {
      model.flagButtonTapped(reminder)
    }
  }

  private func priorityButton(
    _ title: String,
    priority: Reminder.Priority?
  ) -> some View {
    Button {
      model.priorityButtonTapped(reminder, priority: priority)
    } label: {
      if reminder.priority == priority {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}
