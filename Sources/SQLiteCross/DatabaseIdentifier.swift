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

extension DatabaseIdentifier {
  /// The identity a file database shares with every process that opens the same path.
  ///
  /// A database private to the connection that opened it is not the same database as any other, so
  /// each one gets a unique identity instead.
  public static func forDatabase(path: DatabasePath) -> Self {
    guard let url = path.fileURL else { return .unique() }
    return Self(rawValue: url.path)
  }
}
