/// A stable identity shared by every process that opens the same SQLite database.
///
/// A transport may derive this value from a canonical database path, an application-defined
/// identifier, or another value that is stable across process launches.
public struct DatabaseIdentifier: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}
