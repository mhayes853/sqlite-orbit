/// A POSIX file path, and the string operations on it, which touch no file unless they say so.
///
/// These spell out what the package used to ask of Foundation's file `URL`, so that a path is
/// standardized, split and joined exactly as it was, and every process agrees on it however it
/// was built. Where Darwin's Foundation and the others' differ, each platform keeps its own
/// Foundation's answer, which is what identities computed before were made from.
///
/// A path is compared as the string it is, so two spellings of one file are different paths
/// until ``standardized()`` makes them one.
///
/// ```swift
/// let directory: FilePath = "/tmp/sqlite-orbit"
/// let lock = directory.appending("open-locks").appending("db.lock")
/// ```
struct FilePath: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
  /// The path, as the C library is handed it.
  var string: String

  /// Creates a path from its string.
  init(_ string: String) {
    self.string = string
  }

  init(stringLiteral string: String) {
    self.string = string
  }

  var description: String {
    self.string
  }

  /// Whether the path is the empty string.
  var isEmpty: Bool {
    self.string.isEmpty
  }

  /// Whether the path begins at the root, with a slash.
  var isAbsolute: Bool {
    self.string.utf8.first == Self.slash
  }

  // MARK: - Components

  /// The path with `component` appended and one slash between them, as a file `URL` appends a
  /// path component to a directory.
  func appending(_ component: String) -> Self {
    Self(
      self.string.utf8.last == Self.slash ? self.string + component : self.string + "/" + component
    )
  }

  /// The path's last component, or `/` for the root.
  ///
  /// Trailing slashes are ignored, as a file `URL`'s `lastPathComponent` ignores them.
  var lastComponent: String {
    let path = self.removingTrailingSlashes().string
    guard path != "/" else { return path }
    guard let index = path.utf8.lastIndex(of: Self.slash) else { return path }
    return String(decoding: path.utf8[path.utf8.index(after: index)...], as: UTF8.self)
  }

  /// The path with its last component removed, as a file `URL`'s `deletingLastPathComponent()`
  /// then `path` spell it: the parent of `/a/b` is `/a`, the root is its own parent, and so is a
  /// path whose last component is `..`, which is not removed. The parent of a relative path of
  /// one component is the empty path.
  func removingLastComponent() -> Self {
    let path = self.removingTrailingSlashes()
    guard path.string != "/", path.lastComponent != ".." else { return path }
    guard let index = path.string.utf8.lastIndex(of: Self.slash) else { return "" }
    return index == path.string.utf8.startIndex
      ? "/" : Self(String(decoding: path.string.utf8[..<index], as: UTF8.self))
  }

  /// Whether the path is `prefix` or is inside it: `prefix` followed by a slash.
  func starts(with prefix: Self) -> Bool {
    let utf8 = self.string.utf8
    guard utf8.starts(with: prefix.string.utf8) else { return false }
    let end = utf8.index(utf8.startIndex, offsetBy: prefix.string.utf8.count)
    return end == utf8.endIndex || utf8[end] == Self.slash
  }

  // MARK: - Lexical Normalization

  /// The path with trailing slashes removed, leaving `/` alone.
  func removingTrailingSlashes() -> Self {
    guard !self.isEmpty else { return self }
    guard let last = self.string.utf8.lastIndex(where: { $0 != Self.slash }) else { return "/" }
    return Self(String(decoding: self.string.utf8[...last], as: UTF8.self))
  }

  /// The path with each run of slashes replaced with one.
  func compressingSlashes() -> Self {
    var previousWasSlash = false
    let utf8 = self.string.utf8.filter { byte in
      defer { previousWasSlash = byte == Self.slash }
      return !(previousWasSlash && byte == Self.slash)
    }
    return Self(String(decoding: utf8, as: UTF8.self))
  }

  /// The absolute path with its `.` and `..` segments removed by the rules of RFC 3986, section
  /// 5.2.4, as a file `URL` removes them: a `..` removes the segment before it, empty ones
  /// included, and a `..` at the root is dropped.
  func removingDotSegments() -> Self {
    var segments: [ArraySlice<UInt8>] = []
    var endsInDirectory = false
    for segment in self.segments.dropFirst() {
      endsInDirectory = segment.elementsEqual(Self.dot) || segment.elementsEqual(Self.dotDot)
      if segment.elementsEqual(Self.dot) {
        continue
      } else if segment.elementsEqual(Self.dotDot) {
        _ = segments.popLast()
      } else {
        segments.append(segment)
      }
    }
    var utf8: [UInt8] = []
    for segment in segments {
      utf8.append(Self.slash)
      utf8.append(contentsOf: segment)
    }
    if utf8.isEmpty || endsInDirectory {
      utf8.append(Self.slash)
    }
    return Self(String(decoding: utf8, as: UTF8.self))
  }

  /// Whether the path has a component that is exactly `..`.
  var hasDotDotComponent: Bool {
    self.segments.contains { $0.elementsEqual(Self.dotDot) }
  }

  /// The path split at every slash, bytewise, so a combining character after a slash never hides
  /// it, empty segments included.
  private var segments: [ArraySlice<UInt8>] {
    Array(self.string.utf8).split(separator: Self.slash, omittingEmptySubsequences: false)
  }

  private static let slash = UInt8(ascii: "/")
  private static let dot = [UInt8(ascii: ".")]
  private static let dotDot = [UInt8(ascii: "."), UInt8(ascii: ".")]

  // MARK: - Standardizing

  /// The path made absolute and standardized, preserving the platform's original Foundation
  /// file-URL spelling:
  ///
  /// - The path is made absolute as ``absolute()`` makes it, so a tilde at its start is expanded
  ///   outside Darwin and is an ordinary component on Darwin.
  /// - Runs of slashes become one, and trailing slashes go.
  /// - A path that still has a `..` component has its symbolic links resolved, if every
  ///   component of it exists, so each `..` names the parent it does on disk. A `..` after a link
  ///   to a file cannot be resolved, so it is removed as text instead.
  /// - Its `.` and `..` segments are removed, and a path beginning `/private/`,
  ///   `/private/var/automount/` or `/var/automount/` loses that prefix if what is left exists and
  ///   is not in one of the system's top-level directories.
  ///
  /// A relative path is returned unchanged where the current directory cannot be read.
  func standardized() -> Self {
    let path = self.absolute()
    guard path.isAbsolute else { return path }
    return path.standardizingAbsolutePath().removingTrailingSlashes()
  }

  /// The path made absolute with the platform's original Foundation file-URL spelling:
  /// a relative one is resolved against the current
  /// directory, its `.` and `..` segments removed as it is, and trailing slashes go.
  ///
  /// Outside Darwin, a path beginning with a tilde starts from a home directory, as
  /// `expandingTilde()` has it. Darwin takes the tilde for an ordinary component, so `~/db` is
  /// `db` in a directory named `~` in the current directory.
  ///
  /// A relative path is returned unchanged where the current directory cannot be read.
  func absolute() -> Self {
    #if canImport(Darwin)
      var path = self.isEmpty ? "." : self
    #else
      var path = self.isEmpty ? "." : self.expandingTilde()
    #endif
    if !path.isAbsolute {
      guard let currentDirectory = FileSystem.currentDirectory else { return path }
      path = currentDirectory.appending(path.string).removingDotSegments()
    }
    return path.removingTrailingSlashes()
  }

  #if !canImport(Darwin)
    /// The path with a leading `~` replaced by the current user's home directory, and a leading
    /// `~user` by that user's, as Foundation's `expandingTildeInPath` has it. A path naming a user
    /// there is no such user for is returned unchanged.
    func expandingTilde() -> Self {
      let utf8 = self.string.utf8
      guard utf8.first == UInt8(ascii: "~") else { return self }
      let firstSlash = utf8.firstIndex(of: Self.slash) ?? utf8.endIndex
      let afterTilde = utf8.index(after: utf8.startIndex)
      let home: Self
      if firstSlash == afterTilde {
        home = FileSystem.homeDirectory
      } else {
        let user = String(decoding: utf8[afterTilde..<firstSlash], as: UTF8.self)
        guard let userHome = FileSystem.homeDirectory(forUser: user) else { return self }
        home = userHome
      }
      return Self(home.string + String(decoding: utf8[firstSlash...], as: UTF8.self))
    }
  #endif

  /// Standardizes this absolute path as Foundation's `standardizingPath` does, and as its
  /// `resolvingSymlinksInPath()` does once the links are resolved:
  /// runs of slashes become one, trailing slashes go, a `..` is resolved through symbolic links
  /// where every component exists, `.` and `..` segments are removed, and a `/private/`,
  /// `/private/var/automount/` or `/var/automount/` prefix goes if what is left exists and is not
  /// in one of the system's top-level directories.
  func standardizingAbsolutePath() -> Self {
    var result = self.compressingSlashes().removingTrailingSlashes()
    if result.hasDotDotComponent, let resolved = FileSystem.resolvingSymbolicLinks(result) {
      result = resolved
    }
    return result.removingDotSegments().strippingAutomountPrefix()
  }

  /// Resolves every symbolic link in the path if its components all exist, then standardizes
  /// it, as Foundation's `resolvingSymlinksInPath()` does on every platform: with
  /// ``standardizingAbsolutePath()``, which strips a `/private/` prefix there is a file without,
  /// as `/private/var/folders/...` becomes `/var/folders/...` on Darwin. A path that cannot be
  /// resolved is standardized as it is.
  func resolvingSymbolicLinks() -> Self {
    (FileSystem.resolvingSymbolicLinks(self) ?? self).standardizingAbsolutePath()
  }

  private static let automountPrefixes = ["/private/var/automount/", "/var/automount/", "/private/"]

  private static let automountExclusions: [Self] = [
    "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/cores", "/dev", "/opt",
    "/private", "/sbin", "/usr"
  ]

  private func strippingAutomountPrefix() -> Self {
    let utf8 = self.string.utf8
    guard let prefix = Self.automountPrefixes.first(where: { utf8.starts(with: $0.utf8) }) else {
      return self
    }
    // The slash that ends the prefix begins what is left.
    let remainder = Self(String(decoding: utf8.dropFirst(prefix.utf8.count - 1), as: UTF8.self))
    guard !Self.automountExclusions.contains(where: { remainder.starts(with: $0) }),
      FileSystem.fileExists(atPath: remainder)
    else { return self }
    return remainder
  }
}
