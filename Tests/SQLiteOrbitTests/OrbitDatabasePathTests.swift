import Foundation
import Testing

@testable import SQLiteOrbit

@Suite
struct OrbitDatabasePathTests {
  @Test
  func privateDatabasePathsRoundTripThroughSQLitesSpelling() {
    for (sqlitePath, expected) in [
      (":memory:", OrbitDatabasePath.memory),
      ("", OrbitDatabasePath.temporary)
    ] {
      let path = OrbitDatabasePath(sqlitePath)
      #expect(path == expected)
      #expect(path.sqlitePath == sqlitePath)
      #expect(path.isPrivateToConnection)
      #if Foundation
        #expect(path.fileURL == nil)
      #endif
    }
  }

  @Test
  func aFilePathIsAbsoluteAndStandardized() {
    let directory = FileManager.default.currentDirectoryPath
    let path = OrbitDatabasePath("db.sqlite")
    #expect(path.sqlitePath == directory + "/db.sqlite")
    #expect(!path.isPrivateToConnection)
    #expect(
      path == OrbitDatabasePath(directory + "/./db.sqlite")
    )
    #if Foundation
      #expect(path.fileURL?.path == directory + "/db.sqlite")
      #expect(
        path == .file(URL(fileURLWithPath: directory + "/db.sqlite"))
      )
    #endif
  }

  @Test
  func aPathThatLooksLikeAURIIsStillJustAFile() {
    let path = OrbitDatabasePath("file::memory:")
    #expect(!path.isPrivateToConnection)
    #expect(path.sqlitePath.hasSuffix("/file::memory:"))
  }

  @Test
  func aPrivateDatabaseGetsAnIdentityOfItsOwn() {
    #expect(OrbitDatabaseIdentifier.forDatabase(path: .memory) != .forDatabase(path: .memory))
    #expect(OrbitDatabaseIdentifier.forDatabase(path: .temporary) != .forDatabase(path: .temporary))
  }

  @Test
  func aFileDatabaseGetsTheIdentityEveryProcessComputesForIt() {
    let directory = FileManager.default.temporaryDirectory.path
    let identifier = OrbitDatabaseIdentifier.forDatabase(
      path: OrbitDatabasePath(directory + "/db.sqlite")
    )
    let resolvedDirectory = FileManager.default.temporaryDirectory
      .resolvingSymlinksInPath().standardizedFileURL.path
    #expect(identifier.rawValue == resolvedDirectory + "/db.sqlite")
    #expect(identifier == .forDatabase(path: OrbitDatabasePath(directory + "/./db.sqlite")))
  }

  #if canImport(Darwin) || canImport(Glibc)
    @Test
    func aMissingFileKeepsItsIdentityWhenItIsCreated() throws {
      try withTemporaryDirectory("path-identity") { directory in
        let realDirectory = directory.appending(path: "real", directoryHint: .isDirectory)
        let linkDirectory = directory.appending(path: "link", directoryHint: .isDirectory)
        let real = realDirectory.appending(path: "db.sqlite")
        let link = linkDirectory.appending(path: "db.sqlite")
        try FileManager.default.createDirectory(
          at: realDirectory,
          withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
          at: linkDirectory,
          withDestinationURL: realDirectory
        )

        let beforeCreation = OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath(link.path))
        try Data().write(to: real)

        #expect(beforeCreation == .forDatabase(path: OrbitDatabasePath(link.path)))
        #expect(beforeCreation == .forDatabase(path: OrbitDatabasePath(real.path)))
      }
    }

    @Test
    func aDanglingFinalSymbolicLinkUsesItsTargetsIdentity() throws {
      try withTemporaryDirectory("path-identity") { directory in
        let real = directory.appending(path: "real.sqlite")
        let link = directory.appending(path: "link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let beforeCreation = OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath(link.path))
        try Data().write(to: real)

        #expect(beforeCreation == .forDatabase(path: OrbitDatabasePath(link.path)))
        #expect(beforeCreation == .forDatabase(path: OrbitDatabasePath(real.path)))
      }
    }

    // `linked` is a symlink to `real/nested`, so both spellings lead to `real/db.sqlite`: a
    // relative link is read from the directory it really sits in, and `..` after a symlink
    // leaves the symlink's target, as the filesystem resolves them.
    @Test(arguments: [
      (link: "linked/link.sqlite", destination: "../db.sqlite"),
      (link: "link.sqlite", destination: "linked/../db.sqlite")
    ])
    func aRelativeDanglingSymlinkResolvesInFilesystemOrder(
      link: String,
      destination: String
    ) throws {
      try withTemporaryDirectory("path-identity") { directory in
        let nested = directory.appending(path: "real/nested", directoryHint: .isDirectory)
        let linked = directory.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: nested)
        let link = directory.appending(path: link)
        let real = directory.appending(path: "real/db.sqlite")
        try FileManager.default.createSymbolicLink(
          atPath: link.path,
          withDestinationPath: destination
        )

        #expect(
          OrbitDatabaseIdentifier.forDatabase(path: OrbitDatabasePath(link.path))
            == .forDatabase(path: OrbitDatabasePath(real.path))
        )
      }
    }
  #endif
}
