import Foundation

/// Where a SQLite database lives.
///
/// SQLite reads a path string for more than a file name: `":memory:"` and the empty string name
/// databases that are private to the connection that opens them, with no file for a second
/// connection — or a second process — to reach. Naming those outright is what lets a pool refuse a
/// database its readers could never see, and lets an identifier be unique when it has to be,
/// without either of them testing a string for the same special values.
///
/// ```swift
/// let onDisk = OrbitDatabasePath.file(URL.documentsDirectory.appending(path: "reminders.sqlite"))
/// let driver = try SQLiteQueue(path: onDisk)
/// let scratch = try SQLiteQueue(path: .memory)
/// ```
public struct OrbitDatabasePath: Hashable, Sendable {
  private enum Storage: Hashable, Sendable {
    case memory
    case temporary
    case file(String)
  }

  private let storage: Storage

  private init(storage: Storage) {
    self.storage = storage
  }

  /// A database held in memory, private to the connection that opens it.
  public static let memory = Self(storage: .memory)

  /// A database in a file SQLite creates for one connection and deletes when that connection
  /// closes.
  public static let temporary = Self(storage: .temporary)

  /// The database file at `url`.
  ///
  /// - Parameter url: A file URL. It is standardized, so two spellings of one file compare equal.
  /// - Returns: The path naming that file.
  public static func file(_ url: URL) -> Self {
    Self(storage: .file(url.standardizedFileURL.path))
  }

  /// Reads `path` the way SQLite does: `":memory:"` is an in-memory database, the empty string is
  /// a temporary file, and anything else is a file path.
  ///
  /// A relative path is resolved against the current directory, so the same database is the same
  /// `OrbitDatabasePath` however it was spelled.
  ///
  /// - Parameter path: The path SQLite would be handed.
  public init(_ path: String) {
    switch path {
    case ":memory:": self = .memory
    case "": self = .temporary
    default: self = .file(URL(fileURLWithPath: path))
    }
  }

  /// The path handed to `sqlite3_open_v2`.
  ///
  /// A file database resolves to an absolute path, which is also why SQLite can never read one of
  /// these as a `file:` URI on a build that reads URIs by default.
  public var sqlitePath: String {
    switch storage {
    case .memory: ":memory:"
    case .temporary: ""
    case .file(let path): path
    }
  }

  /// The file this database lives in, or `nil` when it has none.
  public var fileURL: URL? {
    guard case .file(let path) = storage else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// Whether the database is private to the connection that opens it.
  ///
  /// Such a database cannot be pooled — a pool's readers would each open a different, empty
  /// database — and cannot be shared with another process.
  public var isPrivateToConnection: Bool {
    if case .file = storage { false } else { true }
  }
}

extension OrbitDatabasePath: ExpressibleByStringLiteral {
  /// Reads a string literal the way ``init(_:)`` does, so `":memory:"` names an in-memory database.
  ///
  /// ```swift
  /// let driver = try SQLiteQueue(path: ":memory:")
  /// ```
  ///
  /// - Parameter value: The path SQLite would be handed.
  public init(stringLiteral value: String) {
    self.init(value)
  }
}

extension OrbitDatabasePath: CustomStringConvertible {
  /// The path SQLite is handed, which is also how a connection queue is labelled.
  public var description: String {
    sqlitePath
  }
}
