import SwiftUI

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
