#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

  enum OrbitDatabaseOpenLock {
    static func withLock<Result>(
      databaseIdentifier: OrbitDatabaseIdentifier,
      directory: URL,
      _ body: () throws -> Result
    ) throws -> Result {
      let locksDirectory = directory.appending(path: "open-locks", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
      let path = locksDirectory.appending(path: "\(databaseIdentifier.coordinationKey).lock").path
      return try UnixSystem.withExclusiveFileLock(atPath: path, body)
    }
  }
#endif
