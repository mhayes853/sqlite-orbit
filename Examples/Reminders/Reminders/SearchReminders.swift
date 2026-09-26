import Observation
import RemindersData
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
final class SearchRemindersModel: ErrorReporting {
  @ObservationIgnored @FetchAll var results: [SearchReminderRow]
  var errorMessage: String?
  var text = ""

  @ObservationIgnored private var searchTask: Task<Void, Never>?
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
    await withErrorReporting {
      try await $results.load(
        Self.query(
          text: text,
          showCompleted: showCompleted
        ),
        animation: .default
      )
    }
  }

  private static func query(
    text: String,
    showCompleted: Bool
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
          isPastDue: $1.isPastDue,
          reminder: $1,
          remindersList: $2
        )
      }
  }
}

struct SearchRemindersView: View {
  @Environment(\.scenePhase) private var scenePhase
  @SingleRow(SearchSettings.self) private var settings: SearchSettings
  let model: SearchRemindersModel
  let remindersLists: [RemindersList]

  init(
    model: SearchRemindersModel,
    remindersLists: [RemindersList]
  ) {
    self.model = model
    self.remindersLists = remindersLists
  }

  var body: some View {
    Section {
      Toggle(
        "Show completed",
        isOn: $settings.binding(\.showCompleted)
      )
    }
    .task(id: model.text) {
      if await model.withErrorReporting({
        try await $settings.load()
        return true
      }) == true {
        model.search(model.text, showCompleted: settings.showCompleted)
      }
    }
    .onChange(of: settings.showCompleted) {
      model.search(
        model.text,
        showCompleted: settings.showCompleted,
        debounce: false
      )
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      if !model.text.isEmpty {
        await model.loadResults(for: model.text, showCompleted: settings.showCompleted)
      }
      await refreshAtDayBoundaries {
        guard !model.text.isEmpty else { return }
        await model.loadResults(for: model.text, showCompleted: settings.showCompleted)
      }
    }

    Section {
      ForEach(model.results) { row in
        ReminderRow(
          color: row.remindersList.color,
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
      ContentUnavailableView.search(text: model.text)
        .listRowBackground(Color.clear)
    }
  }
}
