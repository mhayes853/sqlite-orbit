#if canImport(Darwin) || os(Linux) || os(Android)
  /// An exclusive `flock` on a file that exists only while somebody holds it.
  ///
  /// The lock belongs to the open file, so the kernel lets go of it when the process holding it
  /// dies. The holder unlinks the file before letting go, so lock files do not pile up, one for
  /// everything ever locked. The only ones that remain are those of processes that died holding
  /// them, which ``removeIfUnlocked(atPath:)`` reclaims.
  ///
  /// Unlinking a file others may be waiting on is what makes acquiring take more than one step.
  /// A waiter can open the file just before its holder unlinks it, and then lock a file nobody
  /// else will ever open again while a newcomer creates and locks another at the same path, and
  /// both would hold "the" lock. So a lock only counts once the file it is on is still the one at
  /// the path, and a waiter that finds otherwise starts over. The path cannot change behind a
  /// holder who has checked: only a holder unlinks it, and nothing else can hold the file at the
  /// path without holding this lock.
  enum UnixFileLock {
    /// Runs `body` holding an exclusive lock on the file at `path`, creating the file if needed
    /// and waiting for whoever holds it.
    ///
    /// - Throws: A ``UnixSystemError`` if the file cannot be opened or locked, or whatever `body`
    ///   throws.
    static func withExclusiveLock<Result>(
      atPath path: String,
      _ body: () throws -> Result
    ) throws -> Result {
      // A lock that waits is always taken, so there is always a result.
      try Self.withLock(atPath: path, waits: true) { try body() }!
    }

    /// Runs `body` holding an exclusive lock on the file at `path`, creating the file if needed,
    /// unless somebody else holds it already.
    ///
    /// - Returns: What `body` returned, or `nil`, without running it, if the lock is held.
    /// - Throws: A ``UnixSystemError`` if the file cannot be opened or locked, or whatever `body`
    ///   throws.
    static func withExclusiveLockIfAvailable<Result>(
      atPath path: String,
      _ body: () throws -> Result
    ) throws -> Result? {
      try Self.withLock(atPath: path, waits: false, body)
    }

    /// Removes the lock file at `path` if nobody holds it, as when the process that held it died.
    ///
    /// It takes the lock first, without waiting, and removes only a file that is still the one
    /// at the path, so a lock somebody holds, or has just acquired, is never taken away.
    ///
    /// - Returns: Whether a file was removed. Nothing is removed if nothing is at `path`, the
    ///   lock is held, or the file cannot be opened.
    static func removeIfUnlocked(atPath path: String) -> Bool {
      guard
        let descriptor = try? UnixDescriptor(
          UnixPlatform.openExistingFile(atPath: path),
          from: "open"
        )
      else { return false }
      guard (try? Self.lock(descriptor.rawValue, waits: false)) == true,
        Self.isStillAtPath(descriptor.rawValue, path) == true
      else { return false }
      // Closing the descriptor, when it goes, lets go of the lock, after the file is gone.
      return withExtendedLifetime(descriptor) { UnixPlatform.removeFile(atPath: path) }
    }

    private static func withLock<Result>(
      atPath path: String,
      waits: Bool,
      _ body: () throws -> Result
    ) throws -> Result? {
      while true {
        let descriptor = try UnixDescriptor(
          UnixPlatform.openCreatingFile(atPath: path),
          from: "open"
        )
        guard try Self.lock(descriptor.rawValue, waits: waits) else { return nil }
        guard let isStillAtPath = Self.isStillAtPath(descriptor.rawValue, path) else {
          throw UnixSystemError.last("stat")
        }
        // Its holder unlinked the file while this waited for it, so the lock guards nothing.
        guard isStillAtPath else { continue }
        // Closing the descriptor is what lets go of the lock, so it is held until `body` returns,
        // and the file is unlinked before it is let go of, while nobody else can hold it.
        return try withExtendedLifetime(descriptor) {
          defer { _ = UnixPlatform.removeFile(atPath: path) }
          return try body()
        }
      }
    }

    /// Takes the lock on an open file, retrying a wait a signal interrupts.
    ///
    /// - Returns: Whether the lock was taken, which is always the case if `waits` is `true`.
    private static func lock(_ descriptor: Int32, waits: Bool) throws -> Bool {
      while true {
        let isLocked =
          waits
          ? UnixPlatform.lockExclusively(descriptor)
          : UnixPlatform.tryLockExclusively(descriptor)
        if isLocked { return true }
        let code = UnixPlatform.lastErrorCode
        if code == UnixPlatform.ErrorCode.interrupted { continue }
        if !waits,
          code == UnixPlatform.ErrorCode.wouldBlock || code == UnixPlatform.ErrorCode.tryAgain
        {
          return false
        }
        throw UnixSystemError(operation: "flock", code: code)
      }
    }

    /// Whether the file `descriptor` has open is still the one at `path`.
    ///
    /// - Returns: `false` if another file, or nothing, is at `path`, and `nil` if either could
    ///   not be looked up for any other reason, with `errno` saying why.
    private static func isStillAtPath(_ descriptor: Int32, _ path: String) -> Bool? {
      guard let held = UnixPlatform.fileIdentity(ofDescriptor: descriptor) else { return nil }
      guard let current = UnixPlatform.fileIdentity(atPath: path) else {
        return UnixPlatform.lastErrorCode == UnixPlatform.ErrorCode.noSuchFile ? false : nil
      }
      return held == current
    }
  }
#endif
