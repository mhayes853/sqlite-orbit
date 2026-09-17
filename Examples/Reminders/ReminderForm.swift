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
  private var includesTime: Bool

  var isDateEnabled: Bool {
    get { dueDate != nil }
    set {
      dueDate = newValue ? (dueDate ?? .now) : nil
      if !newValue { includesTime = false }
    }
  }

  var isTimeEnabled: Bool {
    get { includesTime }
    set {
      includesTime = newValue
      if newValue && dueDate == nil { dueDate = .now }
    }
  }

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
    if let dueDate = reminder?.dueDate {
      let components = Calendar.current.dateComponents([.hour, .minute], from: dueDate)
      includesTime = components.hour != 0 || components.minute != 0
    } else {
      includesTime = false
    }
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
    let dueDate = dueDate.map {
      includesTime ? $0 : Calendar.current.startOfDay(for: $0)
    }
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

    return
      text
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
  @FocusState private var focusedField: Field?
  @Environment(\.dismiss) private var dismiss

  fileprivate enum Field: Hashable {
    case notes
    case tags
    case title
  }

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
    @Bindable var model = model

    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        ReminderTextFields(model: model, focusedField: $focusedField)

        ReminderDateAndTimeSection(model: model)

        ReminderOrganizationSection(model: model, remindersLists: remindersLists)

        VStack(alignment: .leading, spacing: 10) {
          Text("Tags & Flags")
            .font(.title3.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)

          VStack(spacing: 0) {
            Label {
              TextField("Tags", text: $model.tagText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .tags)
            } icon: {
              Image(systemName: "number")
                .foregroundStyle(.secondary)
                .frame(width: 30)
            }
            .padding()

            Divider().padding(.leading, 62)

            Toggle(isOn: $model.isFlagged) {
              Label("Flag", systemImage: "flag")
                .labelStyle(RemindersFormLabelStyle())
            }
            .padding()
          }
          .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 22)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Color(.systemGroupedBackground))
    .navigationTitle(model.isNew ? "New Reminder" : "Details")
    .toolbarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel", systemImage: "xmark") { dismiss() }
          .labelStyle(.iconOnly)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save", systemImage: "checkmark", action: saveButtonTapped)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderedProminent)
          .disabled(model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .defaultFocus($focusedField, model.isNew ? .title : nil)
    .alert(
      "Could Not Save Reminder",
      isPresented: $model.errorMessage.isPresented
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }

  private func saveButtonTapped() {
    Task {
      if await model.save() { dismiss() }
    }
  }
}

private struct ReminderTextFields: View {
  @Bindable var model: ReminderFormModel
  var focusedField: FocusState<ReminderFormView.Field?>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      TextField("Title", text: $model.title)
        .font(.title)
        .focused(focusedField, equals: .title)
      TextField("Notes", text: $model.notes, axis: .vertical)
        .font(.body)
        .foregroundStyle(.secondary)
        .lineLimit(2...5)
        .focused(focusedField, equals: .notes)
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
  }
}

private struct ReminderDateAndTimeSection: View {
  @Bindable var model: ReminderFormModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Date & Time")
        .font(.title3.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)

      VStack(spacing: 0) {
        Toggle(isOn: $model.isDateEnabled) {
          Label("Date", systemImage: "calendar")
            .labelStyle(RemindersFormLabelStyle())
        }
        .padding()

        if model.isDateEnabled {
          Divider().padding(.leading, 62)
          DatePicker(
            "Due Date",
            selection: $model.dueDate.value,
            displayedComponents: .date
          )
          .padding()
        }

        Divider().padding(.leading, 62)

        Toggle(isOn: $model.isTimeEnabled) {
          Label("Time", systemImage: "clock")
            .labelStyle(RemindersFormLabelStyle())
        }
        .padding()

        if model.isTimeEnabled {
          Divider().padding(.leading, 62)
          DatePicker(
            "Due Time",
            selection: $model.dueDate.value,
            displayedComponents: .hourAndMinute
          )
          .padding()
        }
      }
      .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
  }
}

private struct ReminderOrganizationSection: View {
  @Bindable var model: ReminderFormModel
  let remindersLists: [RemindersList]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Organization")
        .font(.title3.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)

      VStack(spacing: 0) {
        Picker(selection: $model.remindersListID) {
          ForEach(remindersLists) { list in
            Text(list.title).tag(list.id)
          }
        } label: {
          Label("List", systemImage: "list.bullet")
            .labelStyle(RemindersFormLabelStyle(color: selectedListColor))
        }
        .padding()

        Divider().padding(.leading, 62)

        Picker(selection: $model.priority) {
          Text("None").tag(nil as Reminder.Priority?)
          Text("High").tag(Reminder.Priority.high as Reminder.Priority?)
          Text("Medium").tag(Reminder.Priority.medium as Reminder.Priority?)
          Text("Low").tag(Reminder.Priority.low as Reminder.Priority?)
        } label: {
          Label("Priority", systemImage: "exclamationmark")
            .labelStyle(RemindersFormLabelStyle())
        }
        .padding()
      }
      .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
  }

  private var selectedListColor: Color {
    remindersLists.first { $0.id == model.remindersListID }?.color ?? .blue
  }
}

private struct RemindersFormLabelStyle: LabelStyle {
  var color: Color = .secondary

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 14) {
      configuration.icon
        .foregroundStyle(color)
        .frame(width: 30)
      configuration.title
        .foregroundStyle(.primary)
    }
  }
}
