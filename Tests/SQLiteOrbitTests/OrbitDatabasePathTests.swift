import Foundation
import Testing

@testable import SQLiteOrbit

@Suite
struct OrbitDatabasePathTests {
  @Test(arguments: [":memory:", ""])
  func aPrivateDatabaseIsReadTheWaySQLiteReadsIt(path: String) {
    let path = OrbitDatabasePath(path)
    #expect(path.isPrivateToConnection)
    #expect(path.fileURL == nil)
  }

  @Test
  func theSpecialPathsRoundTripThroughSQLitesOwnSpelling() {
    #expect(OrbitDatabasePath.memory.sqlitePath == ":memory:")
    #expect(OrbitDatabasePath.temporary.sqlitePath == "")
    #expect(OrbitDatabasePath(":memory:") == .memory)
    #expect(OrbitDatabasePath("") == .temporary)
  }

  @Test
  func aFilePathIsAbsoluteHoweverItWasSpelled() {
    let directory = FileManager.default.currentDirectoryPath
    let path = OrbitDatabasePath("db.sqlite")
    #expect(path.sqlitePath == directory + "/db.sqlite")
    #expect(!path.isPrivateToConnection)
    #expect(path.fileURL?.path == directory + "/db.sqlite")
  }

  /// Two spellings of one file are one database, which is what lets an identifier be derived from
  /// the path rather than from whatever string a caller happened to type.
  @Test
  func onlyOneDatabasePathNamesTheSameFile() {
    let directory = FileManager.default.temporaryDirectory.path
    #expect(
      OrbitDatabasePath(directory + "/db.sqlite") == OrbitDatabasePath(directory + "/./db.sqlite")
    )
    #expect(
      OrbitDatabasePath(directory + "/db.sqlite")
        == .file(URL(fileURLWithPath: directory + "/db.sqlite"))
    )
  }

  /// An absolute path can never begin with `file:`, so a SQLite built to read URI filenames by
  /// default cannot reinterpret one of these as something other than a file.
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
    #expect(identifier.rawValue == directory + "/db.sqlite")
    #expect(identifier == .forDatabase(path: OrbitDatabasePath(directory + "/./db.sqlite")))
  }
}
