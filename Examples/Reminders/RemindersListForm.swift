import Observation
import PhotosUI
import RemindersData
import SQLiteOrbit
import SwiftUI

@MainActor
@Observable
final class RemindersListFormModel {
  let id: RemindersList.ID
  let isNew: Bool
  let originalPosition: Int
  var title: String
  var color: Color
  var coverImageData: Data?
  var errorMessage: String?

  init(remindersList: RemindersList?) {
    let database = OrbitDefaultDatabase.current
    id = remindersList?.id ?? UUID()
    isNew = remindersList == nil
    originalPosition = remindersList?.position ?? 0
    title = remindersList?.title ?? ""
    color = remindersList?.color ?? RemindersList.defaultColor
    if let remindersList {
      coverImageData = try? database.readBlocking {
        try RemindersListAsset.find(remindersList.id).select(\.coverImage).fetchOne($0) ?? nil
      }
    }
  }

  func save() async -> Bool {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      errorMessage = "Give the list a name before saving."
      return false
    }
    let id = id
    let color = color
    let coverImageData = coverImageData
    let isNew = isNew
    let originalPosition = originalPosition
    do {
      try await OrbitDefaultDatabase.current.write { transaction in
        let position =
          isNew ? (try RemindersList.count().fetchOne(transaction) ?? 0) : originalPosition
        try RemindersList.upsert {
          RemindersList.Draft(
            RemindersList(id: id, color: color, position: position, title: title)
          )
        }
        .execute(transaction)
        try RemindersListAsset.upsert {
          RemindersListAsset.Draft(
            RemindersListAsset(remindersListID: id, coverImage: coverImageData)
          )
        }
        .execute(transaction)
      }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}

struct RemindersListForm: View {
  @State private var model: RemindersListFormModel
  @State private var photoItem: PhotosPickerItem?
  @FocusState private var isTitleFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(remindersList: RemindersList?) {
    _model = State(
      initialValue: RemindersListFormModel(remindersList: remindersList)
    )
  }

  var body: some View {
    @Bindable var model = model
    let photoButtonTitle = model.coverImageData == nil ? "Choose Photo" : "Replace Photo"

    ScrollView {
      VStack(spacing: 20) {
        VStack(spacing: 28) {
          RemindersListIcon(color: model.color, size: 112)

          TextField("List Name", text: $model.title)
            .font(.title2.bold())
            .foregroundStyle(model.color)
            .multilineTextAlignment(.center)
            .focused($isTitleFocused)
            .submitLabel(.done)
            .padding(.horizontal, 18)
            .frame(minHeight: 64)
            .background(Color(.systemGray5), in: .rect(cornerRadius: 16))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))

        RemindersColorPalette(selection: $model.color)

        VStack(alignment: .leading, spacing: 14) {
          Text("Cover Image")
            .font(.headline)

          if let data = model.coverImageData, let image = UIImage(data: data) {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
              .frame(height: 160)
              .frame(maxWidth: .infinity)
              .clipped()
              .compositingGroup()
              .clipShape(.rect(cornerRadius: 16))
          }

          HStack {
            PhotosPicker(selection: $photoItem, matching: .images) {
              Label(photoButtonTitle, systemImage: "photo")
            }
            .buttonStyle(.bordered)

            if model.coverImageData != nil {
              Button("Remove", systemImage: "trash", role: .destructive) {
                model.coverImageData = nil
              }
              .buttonStyle(.bordered)
            }
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
      }
      .padding(16)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Color(.systemGroupedBackground))
    .navigationTitle(model.isNew ? "New List" : "Edit List")
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
    .defaultFocus($isTitleFocused, model.isNew)
    .onChange(of: photoItem) {
      photoItemChanged()
    }
    .alert(
      "Could Not Save List",
      isPresented: $model.errorMessage.isPresented
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }

  private func photoItemChanged() {
    guard let photoItem else { return }
    Task {
      if let data = try? await photoItem.loadTransferable(type: Data.self) {
        model.coverImageData = resizedImageData(from: data)
      }
      self.photoItem = nil
    }
  }

  private func saveButtonTapped() {
    Task {
      if await model.save() { dismiss() }
    }
  }
}

private struct RemindersColorChoice: Identifiable {
  let id: String
  let color: Color
}

private struct RemindersColorPalette: View {
  @Binding var selection: Color

  private static let choices = [
    RemindersColorChoice(id: "red", color: .red),
    RemindersColorChoice(id: "orange", color: .orange),
    RemindersColorChoice(id: "yellow", color: .yellow),
    RemindersColorChoice(id: "green", color: .green),
    RemindersColorChoice(id: "blue", color: .blue),
    RemindersColorChoice(id: "purple", color: .purple),
    RemindersColorChoice(id: "brown", color: .brown)
  ]

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 14)], spacing: 14) {
      ForEach(Self.choices) { choice in
        RemindersColorButton(choice: choice, selection: $selection)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
  }
}

private struct RemindersColorButton: View {
  let choice: RemindersColorChoice
  @Binding var selection: Color

  private var isSelected: Bool { selection == choice.color }

  var body: some View {
    Button {
      selection = choice.color
    } label: {
      Circle()
        .fill(choice.color.gradient)
        .frame(width: 46, height: 46)
        .padding(5)
        .overlay {
          if isSelected {
            Circle()
              .strokeBorder(.secondary, lineWidth: 3)
          }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(choice.id.capitalized)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private func resizedImageData(from data: Data, maxWidth: CGFloat = 1_000) -> Data? {
  guard let image = UIImage(data: data) else { return nil }
  let scale = min(1, maxWidth / image.size.width)
  let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
  let renderer = UIGraphicsImageRenderer(size: size)
  return renderer.jpegData(withCompressionQuality: 0.8) { _ in
    image.draw(in: CGRect(origin: .zero, size: size))
  }
}
