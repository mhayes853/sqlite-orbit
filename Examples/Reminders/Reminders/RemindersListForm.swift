import Observation
import PhotosUI
import RemindersData
import RemindersUI
import SQLiteOrbit
import SwiftUI

@MainActor
@Observable
final class RemindersListFormModel: ErrorReporting, Identifiable {
  let id: RemindersList.ID
  let isNew: Bool
  let originalPosition: Int
  var title: String
  var color: Color
  private(set) var coverImage: RemindersCoverImage?
  var errorMessage: String?
  @ObservationIgnored private var coverImageWasChanged = false

  init(remindersList: RemindersList?) {
    id = remindersList?.id ?? UUID()
    isNew = remindersList == nil
    originalPosition = remindersList?.position ?? 0
    title = remindersList?.title ?? ""
    color = remindersList?.color ?? RemindersList.defaultColor
  }

  func load() async {
    guard !isNew else { return }
    await withErrorReporting {
      let data = try await OrbitDefaultDatabase.current.read {
        try RemindersListAsset.find(id).select(\.coverImage).fetchOne($0) ?? nil
      }
      guard !coverImageWasChanged else { return }
      if let data {
        coverImage = await RemindersCoverImage.load(data)
      } else {
        coverImage = nil
      }
    }
  }

  func photoSelected(_ data: Data) async {
    guard
      let coverImage = await RemindersCoverImage.load(
        data,
        compressionQuality: 0.8
      )
    else { return }
    coverImageWasChanged = true
    self.coverImage = coverImage
  }

  func removeCoverImageButtonTapped() {
    coverImageWasChanged = true
    coverImage = nil
  }

  func save() async -> Bool {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      errorMessage = "Give the list a name before saving."
      return false
    }
    let id = id
    let color = color
    let coverImageData = coverImage?.data
    let shouldSaveCoverImage = isNew || coverImageWasChanged
    let isNew = isNew
    let originalPosition = originalPosition
    return await withErrorReporting {
      try await OrbitDefaultDatabase.current.write { transaction in
        let position = isNew
          ? (try RemindersList.order { $0.position.desc() }
            .select(\.position).fetchOne(transaction) ?? -1) + 1
          : originalPosition
        try RemindersList.upsert {
          RemindersList.Draft(
            RemindersList(id: id, color: color, position: position, title: title)
          )
        }
        .execute(transaction)
        if shouldSaveCoverImage {
          try RemindersListAsset.upsert {
            RemindersListAsset.Draft(
              RemindersListAsset(remindersListID: id, coverImage: coverImageData)
            )
          }
          .execute(transaction)
        }
      }
      return true
    } ?? false
  }
}

struct RemindersListForm: View {
  @Bindable var model: RemindersListFormModel
  @State private var photoItem: PhotosPickerItem?
  @FocusState private var isTitleFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(model: RemindersListFormModel) {
    self.model = model
  }

  var body: some View {
    let photoButtonTitle = model.coverImage == nil ? "Choose Photo" : "Replace Photo"

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

          if let image = model.coverImage {
            Image(uiImage: image.uiImage)
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

            if model.coverImage != nil {
              Button("Remove", systemImage: "trash", role: .destructive) {
                model.removeCoverImageButtonTapped()
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
    .task { await model.load() }
    .onChange(of: photoItem) {
      photoItemChanged()
    }
    .errorAlert(
      "Could Not Save List",
      message: $model.errorMessage
    )
  }

  private func photoItemChanged() {
    guard let photoItem else { return }
    Task {
      if let data = try? await photoItem.loadTransferable(type: Data.self) {
        await model.photoSelected(data)
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
        let isSelected = selection == choice.color
        Button {
          selection = choice.color
        } label: {
          Circle()
            .fill(choice.color.gradient)
            .frame(width: 46, height: 46)
            .padding(5)
            .overlay {
              if isSelected {
                Circle().strokeBorder(.secondary, lineWidth: 3)
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.id.capitalized)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
  }
}
