#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

  /// The lock a process holds on a database while it opens it, one file per database in the
  /// coordination directory's `open-locks/`.
  ///
  /// Each file exists only while it is held, as ``UnixFileLock`` describes, so the directory
  /// holds nothing but the locks being held and those left behind by processes that died holding
  /// them.
  enum OrbitDatabaseOpenLock {
    static func withLock<Result>(
      databaseIdentifier: OrbitDatabaseIdentifier,
      directory: URL,
      _ body: () throws -> Result
    ) throws -> Result {
      let locksDirectory = Self.locksDirectory(in: directory)
      try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
      let path = locksDirectory.appending(path: "\(databaseIdentifier.coordinationKey).lock").path
      return try UnixFileLock.withExclusiveLock(atPath: path, body)
    }

    /// Removes every lock file in the coordination directory `directory` that nobody holds.
    ///
    /// - Returns: How many were removed.
    @discardableResult
    static func removeUnheldLocks(directory: URL) -> Int {
      let locksDirectory = Self.locksDirectory(in: directory)
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: locksDirectory.path)
      else { return 0 }
      return names.count { name in
        name.hasSuffix(".lock")
          && UnixFileLock.removeIfUnlocked(atPath: locksDirectory.appending(path: name).path)
      }
    }

    private static func locksDirectory(in directory: URL) -> URL {
      directory.appending(path: "open-locks", directoryHint: .isDirectory)
    }
  }
#endif
