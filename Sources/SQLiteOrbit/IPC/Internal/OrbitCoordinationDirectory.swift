#if canImport(Darwin) || os(Linux) || os(Android)
  /// A coordination directory, which the processes that share it coordinate through, and where
  /// each thing in it goes:
  ///
  /// - `open-locks/`: a lock for each database a process is opening, as ``OrbitDatabaseOpenLock``
  ///   takes it.
  /// - `v1/s/`: the socket of each Unix datagram endpoint.
  /// - `v1/d/`: a directory for each database, holding each endpoint's marker for it.
  /// - `v1/cleanup-stale.lock`: the lock a sweep for what dead endpoints left holds.
  ///
  /// The path is made absolute once, when this is created, so everything in the directory is
  /// found in the same place however the current directory changes after.
  struct OrbitCoordinationDirectory: Hashable, Sendable {
    /// The directory's absolute path.
    let path: String

    /// - Parameter path: The directory's path. A relative one is resolved against the current
    ///   directory, as ``FilePath/absolute(_:)`` resolves it.
    init(path: String) {
      self.path = FilePath.absolute(path)
    }

    /// Where each database's open lock goes.
    var openLocksDirectory: String {
      FilePath.appending("open-locks", to: self.path)
    }

    /// Where everything of the Unix datagram transport's goes, versioned with its layout.
    var versionDirectory: String {
      FilePath.appending("v1", to: self.path)
    }

    /// Where each endpoint's socket goes.
    var socketsDirectory: String {
      FilePath.appending("s", to: self.versionDirectory)
    }

    /// Where each database's directory of markers goes.
    var databasesDirectory: String {
      FilePath.appending("d", to: self.versionDirectory)
    }

    /// The lock a sweep for what dead endpoints left holds while it runs.
    var staleCleanupLock: String {
      FilePath.appending("cleanup-stale.lock", to: self.versionDirectory)
    }
  }
#endif
