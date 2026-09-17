import Observation
import SQLiteOrbit
import SwiftUI

@Selection
nonisolated struct SearchReminderRow: Identifiable, Sendable {
  var id: Reminder.ID { reminder.id }
  let highlightedNotes: String
  let highlightedTags: String
  let highlightedTitle: String
  let isPastDue: Bool
  let reminder: Reminder
  let remindersList: RemindersList
}

@MainActor
@Observable
final class SearchRemindersModel {
  @ObservationIgnored @FetchAll var results: [SearchReminderRow]
  var errorMessage: String?

  @ObservationIgnored private let database: RemindersDatabase
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private let now: Date

  init(database: RemindersDatabase, now: Date = .now) {
    self.database = database
    self.now = now
    _results = FetchAll(wrappedValue: [])
  }

  func search(_ text: String, showCompleted: Bool, debounce: Bool = true) {
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      guard let self else { return }
      if debounce {
        try? await Task.sleep(for: .milliseconds(250))
      }
      guard !Task.isCancelled else { return }
      await loadResults(for: text, showCompleted: showCompleted)
    }
  }

  func loadResults(for text: String, showCompleted: Bool) async {
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

  private static func query(
    text: String,
    showCompleted: Bool,
    now: Date
  ) -> some Statement<SearchReminderRow> {
    let match =
      text
      .split(separator: " ")
      .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
      .joined(separator: " ")
    return
      ReminderText
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
        SearchReminderRow.Columns(
          highlightedNotes: $0.notes.snippet("**", "**", "...", 64).replace("\n", " "),
          highlightedTags: $0.tags.highlight("**", "**"),
          highlightedTitle: $0.title.highlight("**", "**"),
          isPastDue: $1.isPastDue(relativeTo: now),
          reminder: $1,
          remindersList: $2
        )
      }
  }
}

struct SearchRemindersView: View {
  @SingleRow private var settings: SearchSettings
  let database: RemindersDatabase
  let model: SearchRemindersModel
  let remindersLists: [RemindersList]
  let searchText: String

  init(
    database: RemindersDatabase,
    model: SearchRemindersModel,
    remindersLists: [RemindersList],
    searchText: String
  ) {
    self.database = database
    self.model = model
    self.remindersLists = remindersLists
    self.searchText = searchText
    _settings = SingleRow(SearchSettings.self, database: database)
  }

  var body: some View {
    Section {
      Toggle(
        "Show completed",
        isOn: $settings.binding(\.showCompleted)
      )
    }
    .task(id: searchText) {
      do {
        try await $settings.load()
        model.search(searchText, showCompleted: settings.showCompleted)
      } catch {
        model.errorMessage = error.localizedDescription
      }
    }
    .onChange(of: settings.showCompleted) {
      model.search(
        searchText,
        showCompleted: settings.showCompleted,
        debounce: false
      )
    }

    Section {
      ForEach(model.results) { row in
        ReminderRow(
          color: row.remindersList.color,
          database: database,
          highlightedTitle: row.highlightedTitle,
          isPastDue: row.isPastDue,
          notes: row.highlightedNotes,
          reminder: row.reminder,
          remindersList: row.remindersList,
          remindersLists: remindersLists,
          tags: row.highlightedTags
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
