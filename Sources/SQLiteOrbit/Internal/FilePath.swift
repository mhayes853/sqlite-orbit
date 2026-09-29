/// String operations on POSIX file paths, which touch no file.
///
/// These spell out what the package used to ask of Foundation's file `URL`, so that a path is
/// standardized, split and joined exactly as it was, and every process agrees on it however it
/// was built. Where Darwin's Foundation and the others' differ, each platform keeps its own
/// Foundation's answer, which is what identities computed before were made from.
enum FilePath {
  /// `component` appended to `base` with one slash between them, as a file `URL` appends a path
  /// component to a directory.
  static func appending(_ component: String, to base: String) -> String {
    base.utf8.last == slash ? base + component : base + "/" + component
  }

  /// The path's last component, or `/` for the root.
  ///
  /// Trailing slashes are ignored, as a file `URL`'s `lastPathComponent` ignores them.
  static func lastComponent(of path: String) -> String {
    let path = droppingTrailingSlashes(path)
    guard path != "/" else { return path }
    guard let index = path.utf8.lastIndex(of: slash) else { return path }
    return String(decoding: path.utf8[path.utf8.index(after: index)...], as: UTF8.self)
  }

  /// The path with its last component removed, as a file `URL`'s `deletingLastPathComponent()`
  /// then `path` spell it: the parent of `/a/b` is `/a`, the root is its own parent, and so is a
  /// path whose last component is `..`, which is not removed.
  static func deletingLastComponent(of path: String) -> String {
    let path = droppingTrailingSlashes(path)
    guard path != "/", lastComponent(of: path) != ".." else { return path }
    guard let index = path.utf8.lastIndex(of: slash) else { return "" }
    return index == path.utf8.startIndex
      ? "/" : String(decoding: path.utf8[..<index], as: UTF8.self)
  }

  /// Replaces each run of slashes with one.
  static func compressingSlashes(_ path: String) -> String {
    var previousWasSlash = false
    let utf8 = path.utf8.filter { byte in
      defer { previousWasSlash = byte == slash }
      return !(previousWasSlash && byte == slash)
    }
    return String(decoding: utf8, as: UTF8.self)
  }

  /// Removes trailing slashes, leaving `/` alone.
  static func droppingTrailingSlashes(_ path: String) -> String {
    guard !path.isEmpty else { return path }
    guard let last = path.utf8.lastIndex(where: { $0 != slash }) else { return "/" }
    return String(decoding: path.utf8[...last], as: UTF8.self)
  }

  /// Removes `.` and `..` segments from an absolute path by the rules of RFC 3986, section
  /// 5.2.4, as a file `URL` does: a `..` removes the segment before it, empty ones included, and
  /// a `..` at the root is dropped.
  static func removingDotSegments(_ path: String) -> String {
    var segments: [ArraySlice<UInt8>] = []
    var endsInDirectory = false
    for segment in Self.segments(of: path).dropFirst() {
      endsInDirectory = segment.elementsEqual(dot) || segment.elementsEqual(dotDot)
      if segment.elementsEqual(dot) {
        continue
      } else if segment.elementsEqual(dotDot) {
        _ = segments.popLast()
      } else {
        segments.append(segment)
      }
    }
    var utf8: [UInt8] = []
    for segment in segments {
      utf8.append(slash)
      utf8.append(contentsOf: segment)
    }
    if utf8.isEmpty || endsInDirectory {
      utf8.append(slash)
    }
    return String(decoding: utf8, as: UTF8.self)
  }

  /// Whether the path has a component that is exactly `..`.
  static func hasDotDotComponent(_ path: String) -> Bool {
    segments(of: path).contains { $0.elementsEqual(dotDot) }
  }

  /// Whether `path` is `prefix` or is inside it: `prefix` followed by a slash.
  static func hasPathPrefix(_ path: some StringProtocol, _ prefix: String) -> Bool {
    guard path.utf8.starts(with: prefix.utf8) else { return false }
    let end = path.utf8.index(path.utf8.startIndex, offsetBy: prefix.utf8.count)
    return end == path.utf8.endIndex || path.utf8[end] == slash
  }

  /// The path split at every slash, bytewise, so a combining character after a slash never hides
  /// it, empty segments included.
  private static func segments(of path: String) -> [ArraySlice<UInt8>] {
    Array(path.utf8).split(separator: slash, omittingEmptySubsequences: false)
  }

  private static let slash = UInt8(ascii: "/")
  private static let dot = [UInt8(ascii: ".")]
  private static let dotDot = [UInt8(ascii: "."), UInt8(ascii: ".")]

  /// A file path made absolute and standardized, exactly as the platform's Foundation spells
  /// `URL(fileURLWithPath: path).standardizedFileURL.path`:
  ///
  /// - The path is made absolute as ``absolute(_:)`` makes it, so a tilde at its start is expanded
  ///   outside Darwin and is an ordinary component on Darwin.
  /// - Runs of slashes become one, and trailing slashes go.
  /// - On Darwin, `.` and `..` segments are then removed by the rules of RFC 3986, without
  ///   looking at the file system, so a `..` after a symbolic link names the directory the link
  ///   is in.
  /// - Elsewhere, a path that still has a `..` component has its symbolic links resolved, if
  ///   every component of it exists, so each `..` names the parent it does on disk. Then its `.`
  ///   and `..` segments are removed, and a path beginning `/private/`, `/private/var/automount/`
  ///   or `/var/automount/` loses that prefix if what is left exists and is not in one of the
  ///   system's top-level directories.
  ///
  /// A relative path is returned unchanged where the current directory cannot be read.
  static func standardized(_ path: String) -> String {
    let path = absolute(path)
    guard path.utf8.first == slash else { return path }
    #if canImport(Darwin)
      return droppingTrailingSlashes(removingDotSegments(compressingSlashes(path)))
    #else
      return droppingTrailingSlashes(standardizingAbsolutePath(path))
    #endif
  }

  /// A file path made absolute as the platform's Foundation spells
  /// `URL(fileURLWithPath: path).path`: a relative one is resolved against the current
  /// directory, its `.` and `..` segments removed as it is, and trailing slashes go.
  ///
  /// Outside Darwin, a path beginning with a tilde starts from a home directory, as
  /// `expandingTilde(_:)` has it. Darwin takes the tilde for an ordinary component, so `~/db` is
  /// `db` in a directory named `~` in the current directory.
  ///
  /// A relative path is returned unchanged where the current directory cannot be read.
  static func absolute(_ path: String) -> String {
    #if canImport(Darwin)
      var path = path.isEmpty ? "." : path
    #else
      var path = path.isEmpty ? "." : expandingTilde(path)
    #endif
    if path.utf8.first != slash {
      guard let currentDirectory = FileSystem.currentDirectoryPath else { return path }
      path = removingDotSegments(appending(path, to: currentDirectory))
    }
    return droppingTrailingSlashes(path)
  }

  #if !canImport(Darwin)
    /// The path with a leading `~` replaced by the current user's home directory, and a leading
    /// `~user` by that user's, as Foundation's `expandingTildeInPath` has it. A path naming a user
    /// there is no such user for is returned unchanged.
    static func expandingTilde(_ path: String) -> String {
      guard path.utf8.first == UInt8(ascii: "~") else { return path }
      let firstSlash = path.utf8.firstIndex(of: slash) ?? path.utf8.endIndex
      let afterTilde = path.utf8.index(after: path.utf8.startIndex)
      let home: String
      if firstSlash == afterTilde {
        home = FileSystem.homeDirectoryPath
      } else {
        let user = String(decoding: path.utf8[afterTilde..<firstSlash], as: UTF8.self)
        guard let userHome = FileSystem.homeDirectoryPath(forUser: user) else { return path }
        home = userHome
      }
      return home + String(decoding: path.utf8[firstSlash...], as: UTF8.self)
    }
  #endif

  /// Standardizes an absolute path as Foundation's `standardizingPath` does outside Darwin, and
  /// as its `resolvingSymlinksInPath()` does on every platform once the links are resolved:
  /// runs of slashes become one, trailing slashes go, a `..` is resolved through symbolic links
  /// where every component exists, `.` and `..` segments are removed, and a `/private/`,
  /// `/private/var/automount/` or `/var/automount/` prefix goes if what is left exists and is not
  /// in one of the system's top-level directories.
  static func standardizingAbsolutePath(_ path: String) -> String {
    var result = droppingTrailingSlashes(compressingSlashes(path))
    if hasDotDotComponent(result), let resolved = FileSystem.resolvingSymbolicLinks(result) {
      result = resolved
    }
    result = removingDotSegments(result)
    return strippingAutomountPrefix(result)
  }

  /// Resolves every symbolic link in a path whose components all exist, then standardizes it,
  /// as Foundation's `resolvingSymlinksInPath()` does on every platform: with
  /// ``standardizingAbsolutePath(_:)``, which strips a `/private/` prefix there is a file without,
  /// as `/private/var/folders/...` becomes `/var/folders/...` on Darwin. A path that cannot be
  /// resolved is standardized as it is.
  static func resolvingSymbolicLinks(_ path: String) -> String {
    standardizingAbsolutePath(FileSystem.resolvingSymbolicLinks(path) ?? path)
  }

  private static let automountPrefixes = ["/private/var/automount/", "/var/automount/", "/private/"]

  private static let automountExclusions = [
    "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/cores", "/dev", "/opt",
    "/private", "/sbin", "/usr"
  ]

  private static func strippingAutomountPrefix(_ path: String) -> String {
    guard let prefix = automountPrefixes.first(where: { path.utf8.starts(with: $0.utf8) }) else {
      return path
    }
    // The slash that ends the prefix begins what is left.
    let remainder = String(decoding: path.utf8.dropFirst(prefix.utf8.count - 1), as: UTF8.self)
    guard !automountExclusions.contains(where: { hasPathPrefix(remainder, $0) }),
      FileSystem.fileExists(atPath: remainder)
    else { return path }
    return remainder
  }
}
