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
///   id: OrbitDatabaseIdentifier(rawValue: "reminders")
/// )
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
    Self(rawValue: UUID().uuidString.lowercased())
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
  /// let id = OrbitDatabaseIdentifier.forDatabase(path: .file(url))
  /// ```
  ///
  /// - Parameter path: Where the database lives.
  /// - Returns: The canonical file path, or a unique identity for a private database.
  public static func forDatabase(path: OrbitDatabasePath) -> Self {
    guard let url = path.fileURL else { return .unique() }
    return Self(rawValue: canonicalFileURL(url).path)
  }

  private static func canonicalFileURL(
    _ url: URL,
    remainingSymbolicLinks: Int = 40
  ) -> URL {
    guard remainingSymbolicLinks > 0 else { return url.standardizedFileURL }

    var existingPrefix = url
    // Collected from the leaf up, so they go back on in reverse.
    var missingComponents: [String] = []
    func reattachingMissingComponents(to base: URL) -> URL {
      missingComponents.reversed().reduce(base) { $0.appending(path: $1) }
    }
    while true {
      do {
        let values = try existingPrefix.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true,
          let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: existingPrefix.path
          )
        {
          let parent = canonicalFileURL(
            existingPrefix.deletingLastPathComponent(),
            remainingSymbolicLinks: remainingSymbolicLinks - 1
          )
          let targetPath =
            (destination as NSString).isAbsolutePath
            ? destination
            : parent.path + "/" + destination
          return canonicalFileURL(
            reattachingMissingComponents(to: URL(fileURLWithPath: targetPath)),
            remainingSymbolicLinks: remainingSymbolicLinks - 1
          )
        }

        return reattachingMissingComponents(to: existingPrefix.resolvingSymlinksInPath())
          .standardizedFileURL
      } catch {
        let parent = existingPrefix.deletingLastPathComponent()
        guard parent != existingPrefix else { return url.standardizedFileURL }
        missingComponents.append(existingPrefix.lastPathComponent)
        existingPrefix = parent
      }
    }
  }
}
