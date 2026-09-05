import Foundation

/// An identity shared by every process that opens the same SQLite database.
///
/// Processes recognize each other's writes by comparing identifiers, so peers that should see one
/// another must compute the same one. ``forDatabase(path:)`` does that from the file path;
/// ``unique()`` deliberately does not.
///
/// ```swift
/// let database = OrbitDatabase(
///   writer: try SQLiteQueue(path: ":memory:"),
///   id: DatabaseIdentifier(rawValue: "reminders")
/// )
/// ```
public struct DatabaseIdentifier: RawRepresentable, Codable, Hashable, Sendable {
  /// The identity itself, compared verbatim.
  public let rawValue: String

  /// Creates an identifier from a string every peer is expected to spell the same way.
  ///
  /// - Parameter rawValue: The identity.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Returns a new process-unique database identifier.
  ///
  /// - Returns: An identifier no other process will compute.
  public static func unique() -> Self {
    Self(rawValue: UUID().uuidString.lowercased())
  }
}

extension DatabaseIdentifier {
  /// The identity a file database shares with every process that opens the same path.
  ///
  /// A database private to the connection that opened it is not the same database as any other, so
  /// each one gets a unique identity instead.
  ///
  /// ```swift
  /// let id = DatabaseIdentifier.forDatabase(path: .file(url))
  /// ```
  ///
  /// - Parameter path: Where the database lives.
  /// - Returns: The standardized file path, or a unique identity for a private database.
  public static func forDatabase(path: DatabasePath) -> Self {
    guard let url = path.fileURL else { return .unique() }
    return Self(rawValue: url.path)
  }
}
