/// The name of a database schema attached to a SQLite connection.
///
/// SQLite's primary and temporary schemas are named ``main`` and ``temp``. Additional schemas use
/// the name supplied by `ATTACH DATABASE`. Schema names compare ASCII case-insensitively.
public struct SQLiteSchemaName:
  RawRepresentable,
  Hashable,
  Sendable,
  ExpressibleByStringLiteral,
  CustomStringConvertible
{
  /// The normalized schema name.
  public let rawValue: String

  /// The primary database schema.
  public static let main = Self(rawValue: "main")

  /// The connection-local temporary schema.
  public static let temp = Self(rawValue: "temp")

  /// Creates a schema name.
  ///
  /// - Parameter rawValue: The name used by SQLite.
  public init(rawValue: String) {
    self.rawValue = rawValue.asciiLowercased
  }

  /// Creates a schema name.
  ///
  /// - Parameter name: The name used by SQLite.
  public init(_ name: String) {
    self.init(rawValue: name)
  }

  /// Creates a schema name from a string literal.
  public init(stringLiteral value: String) {
    self.init(rawValue: value)
  }

  /// The normalized name used by SQLite.
  public var description: String {
    rawValue
  }
}
