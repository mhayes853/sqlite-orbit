import Foundation
import Testing

@testable import SQLiteOrbit

/// The package spells paths, the temporary directory and random identifiers without Foundation.
/// Processes built with and without Foundation, and releases from before and after, must agree on
/// every one of them, so each is checked here against what Foundation computes.
@Suite
struct FileSystemTests {
  // MARK: - Standardizing

  @Test(
    arguments: [
      "db.sqlite", "./db.sqlite", "a/../db.sqlite", "a//b/./c/", "../x", "../../../../../../x",
      "", ".", "..", "a/b/..", "~", "~/", "~root/db.sqlite", "~no-such-orbit-user/db.sqlite",
      "~/db.sqlite", "~/a/../db.sqlite",
      "file::memory:", "é/./x", "...", ".hidden/..", "/", "/tmp/", "//tmp///x//",
      "/a/./b/../c", "/../a", "/a/b/../../..", "/tmp/../tmp/x", "/private/tmp/x", "/private",
      "/var/automount/x", "/a/b/.", "/a/%20b"
    ]
  )
  func aPathIsStandardizedAsFoundationStandardizesIt(path: String) {
    #expect(FilePath.standardized(path) == URL(fileURLWithPath: path).standardizedFileURL.path)
  }

  #if canImport(Darwin) || canImport(Glibc)
    @Test
    func dotDotAfterASymbolicLinkIsStandardizedAsFoundationStandardizesIt() throws {
      try withSymbolicLinkFixture { directory in
        for path in [
          "linked/../db.sqlite", "linked/../missing.sqlite", "linked/..", "linked/../../x",
          "real/nested/../db.sqlite", "chain1/..", "loop1/../x"
        ] {
          let absolute = directory.path + "/" + path
          #expect(
            FilePath.standardized(absolute)
              == URL(fileURLWithPath: absolute).standardizedFileURL.path,
            "\(path)"
          )
        }
      }
    }

    @Test
    func symbolicLinksAreResolvedAsFoundationResolvesThem() throws {
      try withSymbolicLinkFixture { directory in
        for path in ["linked", "linked/db.sqlite", "real/db.sqlite", "chain1", "rellink/nested"] {
          let absolute = directory.path + "/" + path
          #expect(
            FilePath.resolvingSymbolicLinks(absolute)
              == URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path,
            "\(path)"
          )
        }
      }
    }

    // MARK: - Canonical Identities

    @Test
    func aFileDatabaseHasTheIdentityFoundationGaveIt() throws {
      try withSymbolicLinkFixture { directory in
        for path in [
          "real/db.sqlite", "real/./db.sqlite", "real/missing.sqlite", "real/missing/a/b.sqlite",
          "linkdir/db.sqlite", "linkdir/missing/x.sqlite", "rellink/db.sqlite",
          "dangling.sqlite", "absdangling", "absdangling/below", "chain1", "chain1/x",
          "loop1", "loop1/x", "linked/up.sqlite", "linked/../db.sqlite", "dotdot.sqlite",
          "trailing/x.sqlite", "linkdir/../real/db.sqlite", "missing/../real/db.sqlite"
        ] {
          let absolute = directory.path + "/" + path
          let identifier = OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath(absolute))
          #expect(identifier.rawValue == foundationIdentity(ofPath: absolute), "\(path)")
        }
      }
    }

    @Test
    func aDatabaseReachedThroughALinkKeepsItsIdentityOnceItIsCreated() throws {
      try withSymbolicLinkFixture { directory in
        let link = directory.path + "/linkdir/created.sqlite"
        let before = OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath(link))
        #expect(FileManager.default.createFile(atPath: link, contents: Data()))

        #expect(before == .forDatabase(path: OrbitDatabasePath(link)))
        #expect(
          before == .forDatabase(path: OrbitDatabasePath(directory.path + "/real/created.sqlite"))
        )
      }
    }
  #endif

  // MARK: - Temporary Directory

  @Test
  func theTemporaryDirectoryIsFoundations() {
    let path = FileSystem.temporaryDirectoryPath
    #expect(path.hasSuffix("/"))
    #expect(URL(fileURLWithPath: path).path == FileManager.default.temporaryDirectory.path)
  }

  #if canImport(Darwin) || os(Linux) || os(Android)
    @Test
    func theDefaultCoordinationDirectoryIsTheOneFoundationComputed() {
      let foundation = FileManager.default.temporaryDirectory
        .appending(path: "sqlite-orbit", directoryHint: .isDirectory)
      #expect(UnixDatagramIPCTransport.Configuration.defaultDirectoryPath == foundation.path)
      #expect(
        UnixDatagramIPCTransport.Configuration.default.directoryPath
          == UnixDatagramIPCTransport.Configuration.defaultDirectoryPath
      )
    }

    @Test
    func aCoordinationKeyIsTheHashInSixteenHexadecimalDigits() {
      for rawValue in ["", "a", "/tmp/db.sqlite", "reminders", "é"] {
        let identifier = OrbitDatabaseIdentifier(rawValue: rawValue)
        #expect(
          identifier.coordinationKey == String(format: "%016llx", rawValue.stableHash),
          "\(rawValue)"
        )
      }
    }
  #endif

  // MARK: - Random UUIDs

  @Test
  func aRandomUUIDIsSpelledAsALowercasedVersion4UUID() {
    var seen = Set<String>()
    for _ in 0..<1_000 {
      let string = RandomUUID.lowercasedString()
      let uuid = UUID(uuidString: string)
      #expect(uuid?.uuidString.lowercased() == string)
      let characters = Array(string)
      #expect(characters.count == 36)
      #expect(characters[14] == "4")
      #expect("89ab".contains(characters[19]))
      #expect(string == string.lowercased())
      seen.insert(string)
    }
    #expect(seen.count == 1_000)
    #expect(OrbitDatabaseIdentifier.unique() != .unique())
  }

  // MARK: - URL Conveniences

  #if Foundation
    @Test
    func aFileURLNamesTheDatabaseItsPathDoes() {
      let directory = FileManager.default.currentDirectoryPath
      for path in ["db.sqlite", "a/../db.sqlite", "/tmp//x/./db.sqlite/"] {
        let url = URL(fileURLWithPath: path)
        #expect(OrbitDatabasePath.file(url) == OrbitDatabasePath(path), "\(path)")
        #expect(
          OrbitDatabasePath(path).fileURL
            == URL(fileURLWithPath: OrbitDatabasePath(path).sqlitePath)
        )
      }
      #expect(OrbitDatabasePath("db.sqlite").fileURL?.path == directory + "/db.sqlite")
      #expect(OrbitDatabasePath.memory.fileURL == nil)
    }

    #if canImport(Darwin) || os(Linux) || os(Android)
      @Test
      func aCoordinationDirectoryURLIsItsPath() {
        let url = URL(fileURLWithPath: "/tmp/coordination", isDirectory: true)
        var configuration = UnixDatagramIPCTransport.Configuration(
          directory: url,
          maximumDatagramByteCount: 1_024
        )
        #expect(configuration.directoryPath == "/tmp/coordination")
        #expect(configuration.directory == url)
        #expect(configuration.maximumDatagramByteCount == 1_024)
        #expect(
          configuration
            == .init(directoryPath: "/tmp/coordination", maximumDatagramByteCount: 1_024)
        )

        configuration.directory = URL(fileURLWithPath: "/tmp/other")
        #expect(configuration.directoryPath == "/tmp/other")
        #expect(
          UnixDatagramIPCTransport.Configuration.defaultDirectory
            == FileManager.default.temporaryDirectory
            .appending(path: "sqlite-orbit", directoryHint: .isDirectory)
        )
        #expect(UnixDatagramIPCTransport.Configuration() == .default)
      }
    #endif

    #if BuiltInSQLite && (canImport(Darwin) || os(Linux) || os(Android))
      @Test
      func aPoolTakesItsOpenLockInACoordinationDirectoryURL() throws {
        try withTemporaryDirectory("pool-url") { directory in
          let coordination = directory.appending(path: "c", directoryHint: .isDirectory)
          let path = OrbitDatabasePath(directory.appending(path: "db.sqlite").path)
          _ = try SQLitePool(path: path, coordinationDirectory: coordination)
          _ = try SQLitePool(
            path: path,
            configuration: .default,
            coordinationDirectory: nil
          )
          var isDirectory: ObjCBool = false
          #expect(
            FileManager.default.fileExists(
              atPath: coordination.appending(path: "open-locks").path,
              isDirectory: &isDirectory
            )
          )
          #expect(isDirectory.boolValue)
        }
      }
    #endif
  #endif
}

#if canImport(Darwin) || canImport(Glibc)
  /// Runs `body` with a directory holding real files, and symbolic links to them in every way
  /// a path can reach a file: absolute and relative, dangling, chained, looping, and with `..`.
  private func withSymbolicLinkFixture(_ body: (URL) throws -> Void) throws {
    try withTemporaryDirectory("links") { directory in
      let manager = FileManager.default
      func link(_ name: String, to destination: String) throws {
        try manager.createSymbolicLink(
          atPath: directory.appending(path: name).path,
          withDestinationPath: destination
        )
      }
      try manager.createDirectory(
        at: directory.appending(path: "real/nested"),
        withIntermediateDirectories: true
      )
      #expect(
        manager.createFile(atPath: directory.appending(path: "real/db.sqlite").path, contents: nil)
      )
      try link("linkdir", to: directory.appending(path: "real").path)
      try link("rellink", to: "real")
      try link("dangling.sqlite", to: "missing.sqlite")
      try link("absdangling", to: "/nonexistent-sqlite-orbit/zzz/db.sqlite")
      try link("chain1", to: "chain2")
      try link("chain2", to: "real/db.sqlite")
      try link("loop1", to: "loop2")
      try link("loop2", to: "loop1")
      try link("linked", to: directory.appending(path: "real/nested").path)
      try link("real/nested/up.sqlite", to: "../db.sqlite")
      try link("dotdot.sqlite", to: "linked/../db.sqlite")
      try link("trailing", to: "real/")
      try body(directory)
    }
  }

  /// The identity a file database had when Foundation computed it, as it did before the package
  /// stopped needing Foundation.
  private func foundationIdentity(ofPath path: String) -> String {
    let stored = URL(fileURLWithPath: path).standardizedFileURL.path
    return foundationCanonicalFileURL(URL(fileURLWithPath: stored)).path
  }

  private func foundationCanonicalFileURL(
    _ url: URL,
    remainingSymbolicLinks: Int = 40
  ) -> URL {
    guard remainingSymbolicLinks > 0 else { return url.standardizedFileURL }

    var existingPrefix = url
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
          let parent = foundationCanonicalFileURL(
            existingPrefix.deletingLastPathComponent(),
            remainingSymbolicLinks: remainingSymbolicLinks - 1
          )
          let targetPath =
            (destination as NSString).isAbsolutePath
            ? destination
            : parent.path + "/" + destination
          return foundationCanonicalFileURL(
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
#endif
