import SQLiteOrbit
import SwiftUI

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

