import ImageIO
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct RemindersCoverImage: Sendable {
  let data: Data
  private let image: CGImage

  var uiImage: UIImage {
    UIImage(cgImage: image)
  }

  private init(data: Data, image: CGImage) {
    self.data = data
    self.image = image
  }

  @concurrent
  static func load(
    _ data: Data,
    maxPixelSize: Int = 2_000,
    compressionQuality: Double? = nil
  ) async -> Self? {
    guard let image = image(from: data, maxPixelSize: maxPixelSize) else { return nil }
    guard let compressionQuality else { return Self(data: data, image: image) }

    let encodedData = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        encodedData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else { return nil }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return Self(data: encodedData as Data, image: image)
  }

  private static func image(from data: Data, maxPixelSize: Int) -> CGImage? {
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
      ] as CFDictionary
    )
  }
}

protocol HashableObject: AnyObject, Hashable {}

extension HashableObject {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs === rhs
  }

  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

@MainActor
protocol ErrorReporting {
  var errorMessage: String? { get nonmutating set }
}

extension ErrorReporting {
  @discardableResult
  func withErrorReporting<Value>(
    _ operation: () async throws -> Value
  ) async -> Value? {
    do {
      return try await operation()
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}

extension Optional {
  var isPresented: Bool {
    get { self != nil }
    set {
      guard !newValue else { return }
      self = nil
    }
  }
}

extension Optional where Wrapped == Date {
  var isEnabled: Bool {
    get { self != nil }
    set { self = newValue ? (self ?? .now) : nil }
  }

  var value: Date {
    get { self ?? .now }
    set { self = newValue }
  }
}

struct FloatingAddButton: View {
  let tint: Color
  let title: String
  let action: () -> Void

  var body: some View {
    if #available(iOS 26, *) {
      Button(title, systemImage: "plus", action: action)
        .labelStyle(.iconOnly)
        .font(.title2)
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .tint(tint)
    } else {
      Button(title, systemImage: "plus", action: action)
        .labelStyle(.iconOnly)
        .font(.title2)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(tint)
    }
  }
}

struct CheckmarkedMenuButton: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if isSelected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}

private struct RemindersSearchModifier: ViewModifier {
  @Binding var search: SearchRemindersModel?
  let prompt: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if let searchModel = search {
      @Bindable var searchModel = searchModel

      content.searchable(
        text: $searchModel.text,
        isPresented: $search.isPresented,
        placement: .toolbar,
        prompt: prompt
      )
      .searchDictationBehavior(.inline(activation: .onSelect))
      .errorAlert("Search Error", message: $searchModel.errorMessage)
    } else {
      content
    }
  }
}

private struct ErrorAlertModifier: ViewModifier {
  let title: LocalizedStringKey
  @Binding var message: String?

  func body(content: Content) -> some View {
    content.alert(
      title,
      isPresented: $message.isPresented
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(message ?? "Unknown error")
    }
  }
}

extension View {
  func errorAlert(
    _ title: LocalizedStringKey = "Database Error",
    message: Binding<String?>
  ) -> some View {
    modifier(ErrorAlertModifier(title: title, message: message))
  }

  func remindersSearchable(
    search: Binding<SearchRemindersModel?>,
    prompt: String
  ) -> some View {
    modifier(
      RemindersSearchModifier(
        search: search,
        prompt: prompt
      )
    )
  }
}
