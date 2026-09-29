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
    let path: FilePath

    /// - Parameter path: The directory's path. A relative one is resolved against the current
    ///   directory, as ``FilePath/absolute()`` resolves it.
    init(path: String) {
      self.path = FilePath(path).absolute()
    }

    /// Where each database's open lock goes.
    var openLocksDirectory: FilePath {
      self.path.appending("open-locks")
    }

    /// Where everything of the Unix datagram transport's goes, versioned with its layout.
    var versionDirectory: FilePath {
      self.path.appending("v1")
    }

    /// Where each endpoint's socket goes.
    var socketsDirectory: FilePath {
      self.versionDirectory.appending("s")
    }

    /// Where each database's directory of markers goes.
    var databasesDirectory: FilePath {
      self.versionDirectory.appending("d")
    }

    /// The lock a sweep for what dead endpoints left holds while it runs.
    var staleCleanupLock: FilePath {
      self.versionDirectory.appending("cleanup-stale.lock")
    }
  }
#endif
