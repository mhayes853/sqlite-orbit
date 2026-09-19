import Observation
import RemindersData
import SQLiteOrbit
import SwiftUI

@MainActor
@Observable
final class ReminderFormModel {
  let id: Reminder.ID
  let isNew: Bool
  var dueDate: Date
  var reminder: Reminder.Draft
  var tagText: String
  private(set) var tagTitles: [String]
  var errorMessage: String?
  private var dueDateMode: DueDateMode

  var isDateEnabled: Bool {
    dueDateMode != .none
  }

  var isTimeEnabled: Bool {
    dueDateMode == .dateAndTime
  }

  private enum DueDateMode {
    case none
    case date
    case dateAndTime
  }

  init(
    remindersList: RemindersList,
    reminder: Reminder? = nil
  ) {
    let database = OrbitDefaultDatabase.current
    id = reminder?.id ?? UUID()
    isNew = reminder == nil
    self.reminder = Reminder.Draft(
      reminder ?? Reminder(id: id, remindersListID: remindersList.id)
    )
    dueDate = reminder?.dueDate ?? .now
    if let dueDate = reminder?.dueDate {
      let components = Calendar.current.dateComponents([.hour, .minute], from: dueDate)
      dueDateMode = components.hour != 0 || components.minute != 0 ? .dateAndTime : .date
    } else {
      dueDateMode = .none
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
      tagTitles = tags ?? []
    } else {
      tagTitles = []
    }
    tagText = ""
  }

  func dateToggleTapped() {
    dueDateMode = isDateEnabled ? .none : .date
  }

  func timeToggleTapped() {
    dueDateMode = isTimeEnabled ? .date : .dateAndTime
  }

  func dateOptionButtonTapped() {
    if !isDateEnabled {
      dueDateMode = .date
    }
  }

  func tagTextChanged() {
    guard tagText.contains(",") else { return }

    let components = tagText.components(separatedBy: ",")
    for component in components.dropLast() {
      addTagTitles(Self.parseTags(component))
    }
    tagText = components.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func tagTextSubmitted() {
    addTagTitles(Self.parseTags(tagText))
    tagText = ""
  }

  func tagSuggestionTapped(_ title: String) {
    addTagTitles([title])
    tagText = ""
  }

  func removeTagButtonTapped(_ title: String) {
    tagTitles.removeAll { $0.caseInsensitiveCompare(title) == .orderedSame }
  }

  func tagSuggestions(from availableTagTitles: [String]) -> [String] {
    let query = tagText.trimmingCharacters(
      in: .whitespacesAndNewlines.union(.init(charactersIn: "#"))
    )
    guard !query.isEmpty else { return [] }

    let selectedTags = Set(tagTitles.map { $0.lowercased() })
    return Array(
      availableTagTitles
        .filter {
          !selectedTags.contains($0.lowercased())
            && $0.localizedCaseInsensitiveContains(query)
        }
        .prefix(5)
    )
  }

  func save() async -> Bool {
    let title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      errorMessage = "Give the reminder a title before saving."
      return false
    }
    let tagTitles = Tag.normalizedTitles(tagTitles + Self.parseTags(tagText))
    let id = id
    let isNew = isNew
    var reminder = reminder
    reminder.dueDate = dueDateToSave
    reminder.title = title
    do {
      try await OrbitDefaultDatabase.current.write { transaction in
        if isNew {
          reminder.position = try Reminder.count().fetchOne(transaction) ?? 0
        }
        try Reminder.upsert { reminder }.execute(transaction)

        try ReminderTag.replaceTags(for: id, with: tagTitles, in: transaction)
      }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private var dueDateToSave: Date? {
    switch dueDateMode {
    case .none:
      nil
    case .date:
      Calendar.current.startOfDay(for: dueDate)
    case .dateAndTime:
      dueDate
    }
  }

  nonisolated static func parseTags(_ text: String) -> [String] {
    Tag.normalizedTitles([text])
  }

  private func addTagTitles(_ titles: [String]) {
    tagTitles = Tag.normalizedTitles(tagTitles + titles)
  }
}

struct ReminderFormContext: Identifiable {
  let id = UUID()
  let remindersList: RemindersList
  var reminder: Reminder?
}

struct ReminderFormView: View {
  @FetchAll private var availableTags: [Tag]
  @FetchAll private var remindersLists: [RemindersList]
  @State private var model: ReminderFormModel
  @FocusState private var focusedField: Field?
  @Environment(\.dismiss) private var dismiss

  fileprivate enum Field: Hashable {
    case notes
    case title
  }

  init(
    remindersList: RemindersList,
    reminder: Reminder? = nil
  ) {
    _availableTags = FetchAll(
      Tag.order(by: \.title),
      animation: .default
    )
    _remindersLists = FetchAll(
      RemindersList.order(by: \.title),
      animation: .default
    )
    _model = State(
      initialValue: ReminderFormModel(
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

        ReminderMoreOptionsSection(
          model: model,
          remindersLists: remindersLists
        )

        ReminderTagsSection(
          model: model,
          availableTagTitles: availableTags.map(\.title)
        )
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 22)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Color(.systemGroupedBackground))
    .safeAreaInset(edge: .bottom) {
      ReminderFormToolbar(model: model)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
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
          .disabled(model.reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
      TextField("Title", text: $model.reminder.title)
        .font(.title.bold())
        .focused(focusedField, equals: .title)
      TextField("Notes", text: $model.reminder.notes, axis: .vertical)
        .font(.body)
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
        ReminderToggleButton(
          title: "Date",
          systemImage: "calendar",
          isOn: model.isDateEnabled,
          action: model.dateToggleTapped
        )
        .padding()

        if model.isDateEnabled {
          VStack(spacing: 0) {
            Divider().padding(.leading, 62)
            DatePicker(
              "Due Date",
              selection: $model.dueDate,
              displayedComponents: .date
            )
            .padding()
          }
          .transition(optionTransition)
        }

        Divider().padding(.leading, 62)

        ReminderToggleButton(
          title: "Time",
          systemImage: "clock",
          isOn: model.isTimeEnabled,
          action: model.timeToggleTapped
        )
        .padding()

        if model.isTimeEnabled {
          VStack(spacing: 0) {
            Divider().padding(.leading, 62)
            DatePicker(
              "Due Time",
              selection: $model.dueDate,
              displayedComponents: .hourAndMinute
            )
            .padding()
          }
          .transition(optionTransition)
        }
      }
      .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
      .animation(.smooth(duration: 0.25), value: model.isDateEnabled)
      .animation(.smooth(duration: 0.25), value: model.isTimeEnabled)
    }
  }

  private var optionTransition: AnyTransition {
    .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
  }
}

private struct ReminderToggleButton: View {
  let title: String
  let systemImage: String
  let isOn: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Label(title, systemImage: systemImage)
          .labelStyle(RemindersFormLabelStyle())
        Spacer()
        Toggle("", isOn: .constant(isOn))
          .labelsHidden()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(isOn ? "On" : "Off")
  }
}

private struct ReminderMoreOptionsSection: View {
  @Bindable var model: ReminderFormModel
  let remindersLists: [RemindersList]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("More Options")
        .font(.title3.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)

      VStack(spacing: 0) {
        ReminderListPicker(model: model, remindersLists: remindersLists)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)

        Divider().padding(.leading, 62)

        Menu {
          priorityButton("None", priority: nil)
          priorityButton("High", priority: .high)
          priorityButton("Medium", priority: .medium)
          priorityButton("Low", priority: .low)
        } label: {
          HStack(spacing: 14) {
            Image(systemName: "exclamationmark")
              .font(.body.weight(.medium))
              .foregroundStyle(.secondary)
              .frame(width: 34, height: 34)
              .accessibilityHidden(true)
            Text("Priority")
              .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(priorityTitle)
              .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption2.bold())
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity, minHeight: 36)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Priority")
        .accessibilityValue(priorityTitle)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
  }

  private var priorityTitle: String {
    switch model.reminder.priority {
    case nil: "None"
    case .high: "High"
    case .medium: "Medium"
    case .low: "Low"
    }
  }

  private func priorityButton(
    _ title: String,
    priority: Reminder.Priority?
  ) -> some View {
    Button {
      model.reminder.priority = priority
    } label: {
      if model.reminder.priority == priority {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}

private struct ReminderListPicker: View {
  @Bindable var model: ReminderFormModel
  let remindersLists: [RemindersList]

  var body: some View {
    Menu {
      ForEach(remindersLists) { list in
        Button {
          model.reminder.remindersListID = list.id
        } label: {
          if list.id == model.reminder.remindersListID {
            Label(list.title, systemImage: "checkmark")
          } else {
            Text(list.title)
          }
        }
      }
    } label: {
      HStack(spacing: 14) {
        RemindersListIcon(color: selectedListColor, size: 34)
        Text("List")
          .foregroundStyle(.primary)
        Spacer(minLength: 12)
        Text(selectedListTitle)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Image(systemName: "chevron.right")
          .font(.footnote.bold())
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 36)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("List")
    .accessibilityValue(selectedListTitle)
  }

  private var selectedListColor: Color {
    remindersLists.first { $0.id == model.reminder.remindersListID }?.color ?? .blue
  }

  private var selectedListTitle: String {
    remindersLists.first { $0.id == model.reminder.remindersListID }?.title ?? "None"
  }
}

private struct ReminderTagsSection: View {
  @Bindable var model: ReminderFormModel
  let availableTagTitles: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Tags")
        .font(.title3.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)

      ReminderTagsField(model: model, availableTagTitles: availableTagTitles)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
  }
}

private struct ReminderTagsField: View {
  @Bindable var model: ReminderFormModel
  let availableTagTitles: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !model.tagTitles.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(model.tagTitles, id: \.self) { title in
              ReminderTagChip(model: model, title: title)
            }
          }
        }
        .scrollIndicators(.hidden)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      Label {
        TextField("Add Tags", text: $model.tagText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit(model.tagTextSubmitted)
          .onChange(of: model.tagText) { model.tagTextChanged() }
      } icon: {
        Image(systemName: "number")
          .foregroundStyle(.secondary)
          .frame(width: 30)
      }

      let suggestions = model.tagSuggestions(from: availableTagTitles)
      if !suggestions.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(suggestions, id: \.self) { title in
              Button {
                model.tagSuggestionTapped(title)
              } label: {
                Label(title, systemImage: "plus")
              }
              .buttonStyle(.bordered)
              .buttonBorderShape(.capsule)
              .controlSize(.small)
              .accessibilityLabel("Add tag \(title)")
            }
          }
        }
        .scrollIndicators(.hidden)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(.smooth(duration: 0.2), value: model.tagTitles)
    .animation(.smooth(duration: 0.2), value: model.tagText)
  }
}

private struct ReminderTagChip: View {
  @Bindable var model: ReminderFormModel
  let title: String

  var body: some View {
    Button {
      model.removeTagButtonTapped(title)
    } label: {
      HStack(spacing: 6) {
        Text("#\(title)")
          .lineLimit(1)
        Image(systemName: "xmark")
          .font(.caption2.bold())
          .accessibilityHidden(true)
      }
      .font(.subheadline.weight(.medium))
      .foregroundStyle(Color.accentColor)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color.accentColor.opacity(0.12), in: .capsule)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Remove tag \(title)")
  }
}

private struct ReminderFormToolbar: View {
  @Bindable var model: ReminderFormModel

  var body: some View {
    HStack {
      Button("Date and Time", systemImage: "calendar.badge.clock") {
        model.dateOptionButtonTapped()
      }
      .foregroundStyle(model.isDateEnabled ? Color.accentColor : .primary)

      Spacer()

      Button("Location", systemImage: "location") {}
        .disabled(true)

      Spacer()

      Button(
        model.reminder.isFlagged ? "Remove Flag" : "Flag",
        systemImage: model.reminder.isFlagged ? "flag.fill" : "flag"
      ) {
        model.reminder.isFlagged.toggle()
      }
      .foregroundStyle(model.reminder.isFlagged ? Color.orange : .secondary)

      Spacer()

      Button("Add Photo", systemImage: "camera") {}
        .disabled(true)
    }
    .labelStyle(.iconOnly)
    .font(.title2)
    .padding(.horizontal, 24)
    .frame(height: 58)
    .reminderFormToolbarBackground()
  }
}

private struct ReminderFormToolbarBackground: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content.glassEffect(.regular, in: .capsule)
    } else {
      content.background(.regularMaterial, in: .capsule)
    }
  }
}

extension View {
  fileprivate func reminderFormToolbarBackground() -> some View {
    modifier(ReminderFormToolbarBackground())
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
