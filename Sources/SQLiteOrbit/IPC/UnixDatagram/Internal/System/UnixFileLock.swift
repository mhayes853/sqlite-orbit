#if canImport(Darwin) || os(Linux) || os(Android)
  /// An exclusive `flock` on a file.
  ///
  /// The lock belongs to the open file, so the kernel lets go of it when the process holding it
  /// dies.
  enum UnixFileLock {
    /// Runs `body` holding an exclusive lock on the file at `path`, creating the file if needed.
    static func withExclusiveLock<Result>(
      atPath path: String,
      _ body: () throws -> Result
    ) throws -> Result {
      let descriptor = try UnixDescriptor(UnixPlatform.openCreatingFile(atPath: path), from: "open")
      while !UnixPlatform.lockExclusively(descriptor.rawValue) {
        let code = UnixPlatform.lastErrorCode
        guard code == UnixPlatform.ErrorCode.interrupted else {
          throw UnixSystemError(operation: "flock", code: code)
        }
      }
      // Closing the descriptor is what lets go of the lock, so it is held until `body` returns.
      return try withExtendedLifetime(descriptor) { try body() }
    }
  }
#endif
