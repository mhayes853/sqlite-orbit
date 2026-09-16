import Observation
import SQLiteOrbit
import SwiftUI

@MainActor
@Observable
final class SearchRemindersModel {
  @ObservationIgnored @FetchAll var results: [ReminderDetailRow]
  var showCompleted = false
  var errorMessage: String?

  @ObservationIgnored private let database: RemindersDatabase
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private let now: Date

  init(database: RemindersDatabase, now: Date = .now) {
    self.database = database
    self.now = now
    _results = FetchAll(wrappedValue: [])
  }

  func search(_ text: String, debounce: Bool = true) {
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      guard let self else { return }
      if debounce {
        try? await Task.sleep(for: .milliseconds(250))
      }
      guard !Task.isCancelled else { return }
      await loadResults(for: text)
    }
  }

  func loadResults(for text: String) async {
    do {
      try await $results.load(
        Self.query(
          text: text,
          showCompleted: showCompleted,
          now: now
        ),
        database: database,
        animation: .default
      )
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func toggleCompleted(searchText: String) {
    showCompleted.toggle()
    search(searchText, debounce: false)
  }

  private static func query(
    text: String,
    showCompleted: Bool,
    now: Date
  ) -> some Statement<ReminderDetailRow> {
    let match = text
      .split(separator: " ")
      .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
      .joined(separator: " ")
    return ReminderText
      .where {
        if match.isEmpty {
          false
        } else {
          $0.match(match)
        }
      }
      .join(Reminder.all) { $0.rowid.eq($1.rowid) }
      .where {
        if !showCompleted {
          !$1.isCompleted
        }
      }
      .order { ($1.isCompleted, $1.dueDate) }
      .join(RemindersList.all) { $1.remindersListID.eq($2.id) }
      .select {
        ReminderDetailRow.Columns(
          reminder: $1,
          remindersList: $2,
          isPastDue: $1.isPastDue(relativeTo: now),
          notes: $0.notes.substr(0, 200),
          tags: $0.tags
        )
      }
  }
}

struct SearchRemindersView: View {
  let database: RemindersDatabase
  let model: SearchRemindersModel
  let searchText: String

  var body: some View {
    Section {
      Toggle(
        "Show completed",
        isOn: Binding(
          get: { model.showCompleted },
          set: { _ in model.toggleCompleted(searchText: searchText) }
        )
      )
    }

    Section {
      ForEach(model.results) { row in
        ReminderRow(
          color: row.remindersList.color,
          database: database,
          isPastDue: row.isPastDue,
          notes: row.notes,
          reminder: row.reminder,
          remindersList: row.remindersList,
          tags: row.tags
        )
      }
    } header: {
      Text("\(model.results.count) Results")
    }

    if model.results.isEmpty {
      ContentUnavailableView.search(text: searchText)
        .listRowBackground(Color.clear)
    }
  }
}
