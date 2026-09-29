#if canImport(Darwin) || os(Linux) || os(Android)
  /// The lock a process holds on a database while it opens it, one file per database in the
  /// coordination directory's `open-locks/`.
  ///
  /// Each file exists only while it is held, as ``UnixFileLock`` describes, so the directory
  /// holds nothing but the locks being held and those left behind by processes that died holding
  /// them.
  ///
  /// A process that dies holding it lets go of it with everything else it held, but one that is
  /// frozen holding it, stopped by a signal or a debugger or suspended by its OS partway through
  /// an open, never does. So a process waits for it the way SQLite waits for its own locks, as
  /// the configuration it opens with says, and gives up as SQLite does, with `SQLITE_BUSY`.
  enum OrbitDatabaseOpenLock {
    /// Runs `body` holding the lock on the database `databaseIdentifier`, waiting for another
    /// process that holds it as `configuration` has SQLite wait for a lock.
    ///
    /// A ``SQLiteConfiguration/busyHandler`` is asked each time the lock is found held, and does
    /// whatever waiting there is itself, as it does for SQLite. Otherwise the wait backs off as
    /// SQLite's own busy timeout does and ends at ``SQLiteConfiguration/busyTimeout``.
    ///
    /// - Throws: A ``SQLiteError`` with `SQLITE_BUSY` if the lock is still held when the wait
    ///   ends, a ``UnixSystemError`` if the lock cannot be taken, or whatever `body` throws.
    static func withLock<Result>(
      databaseIdentifier: OrbitDatabaseIdentifier,
      directory: OrbitCoordinationDirectory,
      configuration: SQLiteConfiguration,
      _ body: () throws -> Result
    ) throws -> Result {
      let locksDirectory = directory.openLocksDirectory
      try FileSystem.createDirectory(atPath: locksDirectory)
      let path = FilePath.appending(
        "\(databaseIdentifier.coordinationKey).lock",
        to: locksDirectory
      )
      let keepsWaiting =
        configuration.busyHandler ?? Self.waiting(within: configuration.busyTimeout)
      if let result = try UnixFileLock.withExclusiveLock(
        atPath: path,
        waitingWhile: keepsWaiting,
        body
      ) {
        return result
      }
      let gaveUp =
        configuration.busyHandler == nil ? "the busy timeout ran out" : "the busy handler gave up"
      throw SQLiteError(
        code: .busy,
        message: """
          database is locked: another process opening "\(databaseIdentifier.rawValue)" held its \
          open lock until \(gaveUp), and may be stopped or suspended
          """
      )
    }

    /// Removes every lock file in the coordination directory `directory` that nobody holds.
    ///
    /// - Returns: How many were removed.
    static func removeUnheldLocks(in directory: OrbitCoordinationDirectory) -> Int {
      let locksDirectory = directory.openLocksDirectory
      return FileSystem.contentsOfDirectoryIfReadable(atPath: locksDirectory)
        .count { name in
          name.hasSuffix(".lock")
            && UnixFileLock.removeIfUnlocked(atPath: FilePath.appending(name, to: locksDirectory))
        }
    }

    /// Waits before each try again as SQLite's own busy timeout waits between tries at its locks:
    /// briefly at first, then 100 ms at a time, and never past `timeout`, counted from now.
    private static func waiting(within timeout: SQLiteBusyTimeout) -> (_ attempt: Int) -> Bool {
      // The milliseconds SQLite sleeps before each try again, the last repeating from then on.
      let delays = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100]
      let deadline = ContinuousClock.now + .milliseconds(timeout.milliseconds)
      return { attempt in
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return false }
        let delay = Duration.milliseconds(delays[min(attempt, delays.count) - 1])
        CurrentThread.sleep(for: min(delay, remaining))
        return true
      }
    }
  }
#endif
