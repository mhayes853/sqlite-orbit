#if canImport(Darwin) || canImport(Glibc)
  import Foundation

  #if canImport(Darwin)
    import Darwin
    private let openUnixPath: @Sendable (UnsafePointer<CChar>, Int32, mode_t) -> Int32 = Darwin.open
    private let closeUnixDescriptor = Darwin.close
  #elseif canImport(Glibc)
    import Glibc
    private let openUnixPath: @Sendable (UnsafePointer<CChar>, Int32, mode_t) -> Int32 = Glibc.open
    private let closeUnixDescriptor = Glibc.close
  #endif

  // Serializes opening a database across every process that shares a coordination directory.
  //
  // SQLite briefly needs an exclusive lock to move a database into WAL mode, so processes that
  // open the same database at the same time can otherwise fail rather than queue. The lock is
  // advisory and is released when the lock file descriptor closes, including when a holder exits.
  enum OrbitDatabaseOpenLock {
    // Runs `body` while holding the exclusive open lock for `databaseIdentifier`.
    //
    // Waiting for the lock blocks the calling thread, matching the blocking database open that it
    // guards.
    static func withLock<Result>(
      databaseIdentifier: OrbitDatabaseIdentifier,
      directory: URL,
      _ body: () throws -> Result
    ) throws -> Result {
      let locksDirectory = directory.appending(path: "open-locks", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
      let path = locksDirectory.appending(path: "\(databaseIdentifier.coordinationKey).lock").path
      let descriptor = path.withCString { openUnixPath($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o666) }
      guard descriptor >= 0 else {
        throw OrbitIPCSystemError(operation: "open", code: errno)
      }
      defer { _ = closeUnixDescriptor(descriptor) }
      while flock(descriptor, LOCK_EX) != 0 {
        let code = errno
        guard code == EINTR else {
          throw OrbitIPCSystemError(operation: "flock", code: code)
        }
      }
      return try body()
    }
  }
#endif
