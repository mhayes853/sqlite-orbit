import Observation
import PhotosUI
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

  @ObservationIgnored private let database: RemindersDatabase

  init(database: RemindersDatabase, remindersList: RemindersList?) {
    self.database = database
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
      try await database.write { transaction in
        let position =
          isNew ? (try RemindersList.count().fetchOne(transaction) ?? 0) : originalPosition
        try RemindersList.upsert {
          RemindersList.Draft(
            RemindersList(id: id, color: color, position: position, title: title)
          )
        }
        .execute(transaction)
        try RemindersListAsset.upsert {
          RemindersListAsset.Draft(remindersListID: id, coverImage: coverImageData)
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

struct RemindersListFormContext: Identifiable {
  let id = UUID()
  var remindersList: RemindersList?
}

struct RemindersListForm: View {
  @State private var model: RemindersListFormModel
  @State private var photoItem: PhotosPickerItem?
  @Environment(\.dismiss) private var dismiss

  init(database: RemindersDatabase, remindersList: RemindersList?) {
    _model = State(
      initialValue: RemindersListFormModel(database: database, remindersList: remindersList)
    )
  }

  var body: some View {
    Form {
      Section {
        TextField("List Name", text: $model.title)
          .font(.title2.bold())
          .foregroundStyle(model.color)
          .multilineTextAlignment(.center)
      }

      ColorPicker("Color", selection: $model.color)

      Section("Cover Image") {
        if let data = model.coverImageData, let image = UIImage(data: data) {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(height: 160)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        PhotosPicker(selection: $photoItem, matching: .images) {
          Label(
            model.coverImageData == nil ? "Choose Photo" : "Replace Photo",
            systemImage: "photo"
          )
        }
        if model.coverImageData != nil {
          Button("Remove Photo", role: .destructive) { model.coverImageData = nil }
        }
      }
    }
    .navigationTitle(model.isNew ? "New List" : "Edit List")
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
    .onChange(of: photoItem) {
      guard let photoItem else { return }
      Task {
        if let data = try? await photoItem.loadTransferable(type: Data.self) {
          model.coverImageData = resizedImageData(from: data)
        }
        self.photoItem = nil
      }
    }
    .alert(
      "Could Not Save List",
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

private func resizedImageData(from data: Data, maxWidth: CGFloat = 1_000) -> Data? {
  guard let image = UIImage(data: data) else { return nil }
  let scale = min(1, maxWidth / image.size.width)
  let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
  let renderer = UIGraphicsImageRenderer(size: size)
  return renderer.jpegData(withCompressionQuality: 0.8) { _ in
    image.draw(in: CGRect(origin: .zero, size: size))
  }
}
