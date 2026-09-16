import Observation
import SQLiteOrbit
import SwiftUI

@MainActor
@Observable
final class ReminderFormModel {
  let id: Reminder.ID
  let isNew: Bool
  var dueDate: Date?
  var isFlagged: Bool
  var notes: String
  var priority: Reminder.Priority?
  var remindersListID: RemindersList.ID
  var tagText: String
  var title: String
  var errorMessage: String?

  @ObservationIgnored private let database: RemindersDatabase
  @ObservationIgnored private let originalStatus: Reminder.Status

  init(
    database: RemindersDatabase,
    remindersList: RemindersList,
    reminder: Reminder? = nil
  ) {
    self.database = database
    id = reminder?.id ?? UUID()
    isNew = reminder == nil
    dueDate = reminder?.dueDate
    isFlagged = reminder?.isFlagged ?? false
    notes = reminder?.notes ?? ""
    priority = reminder?.priority
    remindersListID = reminder?.remindersListID ?? remindersList.id
    title = reminder?.title ?? ""
    originalStatus = reminder?.status ?? .incomplete
    if let reminder {
      let tags = try? database.readBlocking { transaction in
        try Tag
          .order(by: \.title)
          .join(ReminderTag.all) { $0.primaryKey.eq($1.tagID) }
          .where { $1.reminderID.eq(reminder.id) }
          .select { tag, _ in tag.title }
          .fetchAll(transaction)
      }
      tagText = tags?.map { "#\($0)" }.joined(separator: " ") ?? ""
    } else {
      tagText = ""
    }
  }

  func save() async -> Bool {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      errorMessage = "Give the reminder a title before saving."
      return false
    }
    let tagTitles = Self.parseTags(tagText)
    let id = id
    let isNew = isNew
    let dueDate = dueDate
    let isFlagged = isFlagged
    let notes = notes
    let priority = priority
    let remindersListID = remindersListID
    let status = originalStatus
    do {
      try await database.write { transaction in
        if isNew {
          let position = try Reminder.count().fetchOne(transaction) ?? 0
          try Reminder.insert {
            Reminder(
              id: id,
              dueDate: dueDate,
              isFlagged: isFlagged,
              notes: notes,
              position: position,
              priority: priority,
              remindersListID: remindersListID,
              status: status,
              title: title
            )
          }
          .execute(transaction)
        } else {
          try Reminder.find(id)
            .update {
              $0.dueDate = dueDate
              $0.isFlagged = isFlagged
              $0.notes = notes
              $0.priority = priority
              $0.remindersListID = remindersListID
              $0.title = title
            }
            .execute(transaction)
        }

        try ReminderTag.where { $0.reminderID.eq(id) }.delete().execute(transaction)
        for tagTitle in tagTitles {
          try Tag.upsert { Tag.Draft(title: tagTitle) }.execute(transaction)
          try ReminderTag.insert {
            ReminderTag.Draft(id: UUID(), reminderID: id, tagID: tagTitle)
          }
          .execute(transaction)
        }
      }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  nonisolated static func parseTags(_ text: String) -> [String] {
    var seen = Set<String>()
    return text
      .split { $0 == "," || $0.isWhitespace }
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }
}

struct ReminderFormContext: Identifiable {
  let id = UUID()
  let remindersList: RemindersList
  var reminder: Reminder?
}

struct ReminderFormView: View {
  @FetchAll private var remindersLists: [RemindersList]
  @State private var model: ReminderFormModel
  @Environment(\.dismiss) private var dismiss

  init(
    database: RemindersDatabase,
    remindersList: RemindersList,
    reminder: Reminder? = nil
  ) {
    _remindersLists = FetchAll(
      RemindersList.order(by: \.title),
      database: database,
      animation: .default
    )
    _model = State(
      initialValue: ReminderFormModel(
        database: database,
        remindersList: remindersList,
        reminder: reminder
      )
    )
  }

  var body: some View {
    Form {
      TextField("Title", text: $model.title)

      Section("Notes") {
        TextEditor(text: $model.notes).frame(minHeight: 90)
      }

      Section {
        TextField("Tags, separated by spaces or commas", text: $model.tagText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      } header: {
        Label("Tags", systemImage: "number")
      }

      Section {
        Toggle("Date", isOn: Binding(
          get: { model.dueDate != nil },
          set: { model.dueDate = $0 ? (model.dueDate ?? .now) : nil }
        ))
        if model.dueDate != nil {
          DatePicker(
            "Due",
            selection: Binding(
              get: { model.dueDate ?? .now },
              set: { model.dueDate = $0 }
            ),
            displayedComponents: [.date, .hourAndMinute]
          )
        }
      }

      Section {
        Toggle("Flag", isOn: $model.isFlagged)
        Picker("Priority", selection: $model.priority) {
          Text("None").tag(nil as Reminder.Priority?)
          Text("High").tag(Reminder.Priority.high as Reminder.Priority?)
          Text("Medium").tag(Reminder.Priority.medium as Reminder.Priority?)
          Text("Low").tag(Reminder.Priority.low as Reminder.Priority?)
        }
        Picker("List", selection: $model.remindersListID) {
          ForEach(remindersLists) { list in
            Label(list.title, systemImage: "list.bullet").tag(list.id)
          }
        }
      }
    }
    .navigationTitle(model.isNew ? "New Reminder" : "Details")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          Task {
            if await model.save() { dismiss() }
          }
        }
      }
    }
    .alert(
      "Could Not Save Reminder",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }
}
