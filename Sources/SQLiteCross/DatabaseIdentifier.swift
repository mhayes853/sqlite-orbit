import Crypto
import Foundation

/// An identity shared by every process that opens the same SQLite database.
public struct DatabaseIdentifier: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Returns a new process-unique database identifier.
  public static func unique() -> Self {
    Self(rawValue: UUID().uuidString.lowercased())
  }

  static func stable(for path: String) -> Self {
    let digest = SHA256.hash(data: Data(path.utf8))
    let hexadecimal =
      digest.map { byte in
        let component = String(byte, radix: 16)
        return component.count == 1 ? "0" + component : component
      }
      .joined()
    return Self(rawValue: hexadecimal)
  }
}
