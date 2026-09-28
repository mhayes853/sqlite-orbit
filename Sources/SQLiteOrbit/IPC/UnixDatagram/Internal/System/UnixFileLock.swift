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
  ///
  /// `flock` either waits for good or not at all, and a holder that is frozen rather than dead,
  /// stopped by a signal or a debugger or suspended by its OS, never lets go. So whatever must not
  /// wait on such a process takes the lock with ``withExclusiveLock(atPath:waitingWhile:_:)``,
  /// which tries without waiting and asks between tries whether to go on, as SQLite does for its
  /// own locks.
  enum UnixFileLock {
    /// Runs `body` holding an exclusive lock on the file at `path`, creating the file if needed
    /// and waiting for whoever holds it, however long that takes.
    ///
    /// - Throws: A ``UnixSystemError`` if the file cannot be opened or locked, or whatever `body`
    ///   throws.
    static func withExclusiveLock<Result>(
      atPath path: String,
      _ body: () throws -> Result
    ) throws -> Result {
      // A lock that waits is always taken, so there is always a result.
      try Self.withLock(atPath: path, waits: true, keepsWaiting: { _ in true }, body)!
    }

    /// Runs `body` holding an exclusive lock on the file at `path`, creating the file if needed,
    /// and waiting for whoever holds it for as long as `keepsWaiting` says.
    ///
    /// Each try takes the lock without waiting. One that finds it held asks `keepsWaiting`, which
    /// does whatever waiting there is before it answers, as a busy handler does for SQLite: `true`
    /// tries again at once, and `false` gives up. A try that starts over on a file its holder
    /// unlinked has found the lock free, and asks nothing.
    ///
    /// - Parameters:
    ///   - keepsWaiting: Receives how many tries have found the lock held, counting from `1` and
    ///     rising across the whole wait.
    ///   - body: Runs once the lock is held.
    /// - Returns: What `body` returned, or `nil`, without running it, if `keepsWaiting` gave up.
    /// - Throws: A ``UnixSystemError`` if the file cannot be opened or locked, or whatever `body`
    ///   throws.
    static func withExclusiveLock<Result>(
      atPath path: String,
      waitingWhile keepsWaiting: (_ attempt: Int) -> Bool,
      _ body: () throws -> Result
    ) throws -> Result? {
      try Self.withLock(atPath: path, waits: false, keepsWaiting: keepsWaiting, body)
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
      try Self.withLock(atPath: path, waits: false, keepsWaiting: { _ in false }, body)
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
        ),
        (try? Self.lock(descriptor.rawValue, waits: false)) == true,
        Self.isStillAtPath(descriptor.rawValue, path) == true
      else { return false }
      // Closing the descriptor, when it goes, lets go of the lock, after the file is gone.
      return withExtendedLifetime(descriptor) { UnixPlatform.removeFile(atPath: path) }
    }

    /// Takes the lock, waiting in `flock` if `waits`, and otherwise asking `keepsWaiting` each
    /// time a try finds it held.
    private static func withLock<Result>(
      atPath path: String,
      waits: Bool,
      keepsWaiting: (_ attempt: Int) -> Bool,
      _ body: () throws -> Result
    ) throws -> Result? {
      var attempt = 0
      while true {
        let descriptor = try UnixDescriptor(
          UnixPlatform.openCreatingFile(atPath: path),
          from: "open"
        )
        guard try Self.lock(descriptor.rawValue, waits: waits) else {
          attempt += 1
          // Each try opens the path afresh, so it never waits on a file its holder unlinked.
          guard keepsWaiting(attempt) else { return nil }
          continue
        }
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

    /// Takes the lock on an open file.
    ///
    /// - Returns: Whether the lock was taken, which is always the case if `waits` is `true`.
    private static func lock(_ descriptor: Int32, waits: Bool) throws -> Bool {
      if UnixPlatform.lockExclusively(descriptor, waits: waits) { return true }
      let code = UnixPlatform.lastErrorCode
      if !waits, code == UnixPlatform.ErrorCode.wouldBlock { return false }
      throw UnixSystemError(operation: "flock", code: code)
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
