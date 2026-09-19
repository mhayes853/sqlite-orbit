import SwiftUI

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

struct RemindersListIcon: View {
  let color: Color
  var size: CGFloat = 38

  var body: some View {
    Image(systemName: "list.bullet")
      .font(.system(size: size * 0.46, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(color.gradient, in: .circle)
      .accessibilityHidden(true)
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
  @Binding var text: String
  @Binding var isPresented: Bool
  let prompt: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if isPresented {
      content.searchable(
        text: $text,
        isPresented: $isPresented,
        placement: .toolbar,
        prompt: prompt
      )
      .searchDictationBehavior(.inline(activation: .onSelect))
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
    text: Binding<String>,
    isPresented: Binding<Bool>,
    prompt: String
  ) -> some View {
    modifier(
      RemindersSearchModifier(
        text: text,
        isPresented: isPresented,
        prompt: prompt
      )
    )
  }
}
