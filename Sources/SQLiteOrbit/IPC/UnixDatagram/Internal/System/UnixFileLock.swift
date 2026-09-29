#if canImport(Darwin) || os(Linux) || os(Android)
  /// An exclusive `flock` on a file that exists only while somebody holds it.
  ///
  /// The lock belongs to the open file, so the kernel lets go of it when the process holding it
  /// dies. The holder unlinks the file before letting go, so lock files do not pile up, one for
  /// everything ever locked. The only ones that remain are those of processes that died holding
  /// them, which ``removeIfUnlocked(atPath:)`` reclaims.
  ///
  /// `flock` either waits for good or not at all, and a holder that is frozen rather than dead,
  /// stopped by a signal or a debugger or suspended by its OS, never lets go. So nothing ever
  /// waits in `flock`: every try takes the lock without waiting, and one that finds it held asks
  /// whether to try again, as SQLite does for its own locks, so a frozen holder can hold up
  /// others only for as long as they choose to wait.
  ///
  /// Unlinking a file others may be trying for is what makes acquiring take more than one step.
  /// A try can open the file just before its holder unlinks it, and then lock a file nobody else
  /// will ever open again while a newcomer creates and locks another at the same path, and both
  /// would hold "the" lock. So a lock only counts once the file it is on is still the one at the
  /// path, and a try that finds otherwise starts over. The path cannot change behind a holder who
  /// has checked: only a holder unlinks it, and nothing else can hold the file at the path without
  /// holding this lock.
  enum UnixFileLock {
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
      var attempt = 0
      while true {
        // Each try opens the path afresh, so it never waits on a file its holder unlinked.
        let descriptor = try UnixDescriptor(
          UnixPlatform.openCreatingFile(atPath: path),
          from: "open"
        )
        switch try Self.lock(descriptor.rawValue, openedFrom: path) {
        case .held:
          attempt += 1
          guard keepsWaiting(attempt) else { return nil }
        case .unlinked:
          continue
        case .taken:
          // Closing the descriptor is what lets go of the lock, so it is held until `body`
          // returns, and the file is unlinked before it is let go of, while nobody else can hold
          // it.
          return try withExtendedLifetime(descriptor) {
            defer { FileSystem.removeFile(atPath: FilePath(path)) }
            return try body()
          }
        }
      }
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
      try Self.withExclusiveLock(atPath: path, waitingWhile: { _ in false }, body)
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
        (try? Self.lock(descriptor.rawValue, openedFrom: path)) == .taken
      else { return false }
      // Closing the descriptor, when it goes, lets go of the lock, after the file is gone.
      return withExtendedLifetime(descriptor) { FileSystem.removeFile(atPath: FilePath(path)) }
    }

    /// What one try found: the lock taken on the file at the path, held by somebody else, or
    /// taken on a file its holder unlinked between its opening and its locking, which guards
    /// nothing.
    private enum Attempt { case taken, held, unlinked }

    /// Tries once, without waiting, for the lock on the file `descriptor` opened from `path`.
    ///
    /// - Throws: A ``UnixSystemError`` if the lock cannot be tried, or the file looked up.
    private static func lock(_ descriptor: Int32, openedFrom path: String) throws -> Attempt {
      guard UnixPlatform.tryLockExclusively(descriptor) else {
        let code = UnixPlatform.lastErrorCode
        guard code == UnixPlatform.ErrorCode.wouldBlock else {
          throw UnixSystemError(operation: "flock", code: code)
        }
        return .held
      }
      guard let locked = UnixPlatform.fileIdentity(ofDescriptor: descriptor) else {
        throw UnixSystemError.last("stat")
      }
      guard let current = UnixPlatform.fileIdentity(atPath: path) else {
        guard UnixPlatform.lastErrorCode == UnixPlatform.ErrorCode.noSuchFile else {
          throw UnixSystemError.last("stat")
        }
        return .unlinked
      }
      return locked == current ? .taken : .unlinked
    }
  }
#endif
