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
}
