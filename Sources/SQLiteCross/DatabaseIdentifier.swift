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
  /// In-memory databases are private to the connection that opened them, so no two of them are the
  /// same database and each gets a unique identity instead.
  static func forDatabase(path: String) -> Self {
    guard !path.isEmpty, path != ":memory:" else { return .unique() }
    return Self(rawValue: URL(fileURLWithPath: path).standardizedFileURL.path)
  }
}
