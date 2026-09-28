#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

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
      directory: URL,
      configuration: SQLiteConfiguration,
      _ body: () throws -> Result
    ) throws -> Result {
      let locksDirectory = Self.locksDirectory(in: directory)
      try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
      let path = locksDirectory.appending(path: "\(databaseIdentifier.coordinationKey).lock").path
      let busyTimeout = BusyTimeout(configuration.busyTimeout)
      let keepsWaiting: (Int) -> Bool = configuration.busyHandler ?? busyTimeout.keepsWaiting
      guard
        let result = try UnixFileLock.withExclusiveLock(
          atPath: path,
          waitingWhile: keepsWaiting,
          body
        )
      else {
        let gaveUp =
          configuration.busyHandler == nil ? "the busy timeout ran out" : "the busy handler gave up"
        throw SQLiteError(
          code: .busy,
          message: """
            database is locked: another process opening "\(databaseIdentifier.rawValue)" held \
            its open lock until \(gaveUp), and may be stopped or suspended
            """
        )
      }
      return result
    }

    /// Removes every lock file in the coordination directory `directory` that nobody holds.
    ///
    /// - Returns: How many were removed.
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

    /// Waits between tries at the lock as SQLite's own busy timeout waits between tries at its
    /// locks: briefly at first, then 100 ms at a time, and never past the timeout.
    private struct BusyTimeout {
      /// The milliseconds SQLite sleeps before each try again, the last repeating from then on.
      private static let delays = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100]

      private let deadline: ContinuousClock.Instant

      /// Starts the timeout now.
      init(_ timeout: SQLiteBusyTimeout) {
        self.deadline = .now + .milliseconds(timeout.milliseconds)
      }

      /// Sleeps until the next try, cut short at the deadline, and says whether there is one.
      func keepsWaiting(attempt: Int) -> Bool {
        let remaining = ContinuousClock.now.duration(to: self.deadline)
        guard remaining > .zero else { return false }
        let delay = Duration.milliseconds(Self.delays[min(attempt, Self.delays.count) - 1])
        let (seconds, attoseconds) = min(delay, remaining).components
        Thread.sleep(forTimeInterval: Double(seconds) + Double(attoseconds) / 1e18)
        return true
      }
    }
  }
#endif
