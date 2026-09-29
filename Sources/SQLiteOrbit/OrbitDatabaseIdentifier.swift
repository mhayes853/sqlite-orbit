/// An identity shared by every process that opens the same SQLite database.
///
/// Processes recognize each other's writes by comparing identifiers, so peers that should see one
/// another must compute the same one. ``forDatabase(path:)`` does that from the file path;
/// ``unique()`` deliberately does not.
///
/// ```swift
/// let identifier = OrbitDatabaseIdentifier(rawValue: "reminders")
/// ```
public struct OrbitDatabaseIdentifier: RawRepresentable, Codable, Hashable, Sendable {
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
    Self(rawValue: RandomUUID.lowercasedString())
  }
}

extension OrbitDatabaseIdentifier {
  /// The identity a file database shares with every process that opens the same path.
  ///
  /// Symbolic links in the file or any existing parent directory are resolved. The unresolved
  /// suffix of a path is preserved, so creating the database does not change its identity.
  ///
  /// A database private to the connection that opened it is not the same database as any other, so
  /// each one gets a unique identity instead.
  ///
  /// ```swift
  /// let id = OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath("reminders.sqlite"))
  /// ```
  ///
  /// - Parameter path: Where the database lives.
  /// - Returns: The canonical file path, or a unique identity for a private database.
  public static func forDatabase(path: OrbitDatabasePath) -> Self {
    guard let filePath = path.filePath else { return .unique() }
    return Self(rawValue: canonicalFilePath(filePath).string)
  }

  /// The path of the file `path` names once every symbolic link is resolved, including one at
  /// its end whose target does not exist yet.
  ///
  /// The longest prefix of `path` that exists is resolved, and the components past it that do
  /// not exist yet are put back on the end, so a database has the same identity before and after
  /// its file is created. A symbolic link is followed whether its target exists or not, a
  /// relative one from the canonical path of the directory it is in, and the `..` in a target is
  /// taken in the order the file system takes it. Past 40 links, as in a loop, the path is only
  /// standardized.
  ///
  /// - Parameters:
  ///   - path: An absolute path.
  ///   - remainingSymbolicLinks: How many more links may be followed.
  private static func canonicalFilePath(
    _ path: FilePath,
    remainingSymbolicLinks: Int = 40
  ) -> FilePath {
    guard remainingSymbolicLinks > 0 else { return path.standardized() }

    var existingPrefix = path
    // Collected from the leaf up, so they go back on in reverse.
    var missingComponents: [String] = []
    func reattachingMissingComponents(to base: FilePath) -> FilePath {
      missingComponents.reversed().reduce(base) { $0.appending($1) }
    }
    while true {
      guard let entry = FileSystem.entry(atPath: existingPrefix) else {
        let parent = existingPrefix.removingLastComponent()
        guard parent != existingPrefix else { return path.standardized() }
        missingComponents.append(existingPrefix.lastComponent)
        existingPrefix = parent
        continue
      }
      // A link replaced by something else since it was looked at is resolved as it is now.
      if entry == .symbolicLink,
        let destination = FileSystem.symbolicLinkDestination(atPath: existingPrefix)
      {
        let parent = canonicalFilePath(
          existingPrefix.removingLastComponent(),
          remainingSymbolicLinks: remainingSymbolicLinks - 1
        )
        let target =
          destination.isAbsolute
          ? destination
          : FilePath(parent.string + "/" + destination.string)
        return canonicalFilePath(
          reattachingMissingComponents(to: target.removingTrailingSlashes()),
          remainingSymbolicLinks: remainingSymbolicLinks - 1
        )
      }
      return reattachingMissingComponents(to: existingPrefix.resolvingSymbolicLinks())
        .standardized()
    }
  }
}
