import SQLiteOrbit
import SwiftUI

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

extension View {
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

extension Color {
  nonisolated struct HexRepresentation: QueryBindable, QueryDecodable, QueryRepresentable {
    var queryOutput: Color

    init(queryOutput: Color) {
      self.queryOutput = queryOutput
    }

    init(hexValue: Int64) {
      self.init(
        queryOutput: Color(
          red: Double((hexValue >> 24) & 0xff) / 0xff,
          green: Double((hexValue >> 16) & 0xff) / 0xff,
          blue: Double((hexValue >> 8) & 0xff) / 0xff,
          opacity: Double(hexValue & 0xff) / 0xff
        )
      )
    }

    var hexValue: Int64? {
      guard let components = UIColor(queryOutput).cgColor.components else { return nil }
      let red = Int64(components[0] * 0xff) << 24
      let green = Int64(components[1] * 0xff) << 16
      let blue = Int64(components[2] * 0xff) << 8
      let alpha = Int64((components.indices.contains(3) ? components[3] : 1) * 0xff)
      return red | green | blue | alpha
    }

    init?(queryBinding: QueryBinding) {
      guard case .int(let hexValue) = queryBinding else { return nil }
      self.init(hexValue: hexValue)
    }

    var queryBinding: QueryBinding {
      guard let hexValue else {
        struct InvalidColor: Error {}
        return .invalid(InvalidColor())
      }
      return .int(hexValue)
    }

    init(decoder: inout some QueryDecoder) throws {
      try self.init(hexValue: Int64(decoder: &decoder))
    }
  }
}
