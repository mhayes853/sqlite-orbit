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
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in path.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let hexadecimal = String(hash, radix: 16)
    return Self(
      rawValue: String(repeating: "0", count: 16 - hexadecimal.count) + hexadecimal
    )
  }
}
