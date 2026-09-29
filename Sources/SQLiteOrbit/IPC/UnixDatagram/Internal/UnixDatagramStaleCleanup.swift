#if canImport(Darwin) || os(Linux) || os(Android)
  /// Removes what endpoints that died without shutting down left in the coordination directory.
  ///
  /// An endpoint that is killed leaves its socket's file in `v1/s/`, its markers in
  /// `v1/d/<coordination key>/`, and any lock in `open-locks/` it held. A sender prunes a dead peer
  /// it finds among the markers of a database it sends to, but nothing else ever looks at the
  /// databases nobody sends to, or at a socket with no marker leading to it, so each endpoint
  /// sweeps the whole directory once as it starts.
  ///
  /// An endpoint is dead only once nothing is bound at its socket's path, as
  /// ``UnixDatagramSocket/probe(_:)`` finds it, and never because it has been quiet or its files
  /// are old: a stopped process still holds its socket and must keep its markers. The one
  /// exception is the hidden name a socket is bound under before it is renamed into place, which a
  /// live endpoint holds for no longer than a bind takes, and whose file does not yet have a socket
  /// bound to it for an instant after it appears. One found dead is removed only once it is older
  /// than a grace period, which a bind never lasts.
  ///
  /// Every removal is safe against whatever else is going on in the directory:
  /// - An endpoint that is starting renames its socket into place already bound, and writes its
  ///   markers only after that, so neither is ever found dead.
  /// - Anything already removed, by a peer pruning the same endpoint or another sweep, is skipped.
  /// - A database's directory is only ever removed while it is empty, and an endpoint that finds
  ///   it gone creates it again.
  /// - A live endpoint whose socket's file something else deleted is found dead and loses its
  ///   markers, which is what a sender pruning it would do as well, and it writes them again once
  ///   it notices.
  /// - An endpoint is probed again right before each of its files is removed, never once for all
  ///   of them, so a verdict is never acted on later than the removal it is for. A sweep that
  ///   stalls between two removals, its process stopped or suspended in the background for hours,
  ///   finds an endpoint that has come back in the meantime alive, and leaves the rest of its
  ///   files alone.
  ///
  /// Sweeps are one at a time, under a lock no sweep waits for: whoever finds it held skips its
  /// sweep, as the holder is removing the same things. Nothing ever waits on a sweep, so one that
  /// stalls holds up nothing but the sweeps it makes skip, and one whose process dies lets go of
  /// the lock with it, leaving its lock file for the next sweep to take over and remove, and the
  /// rest of what it would have removed for that sweep to find.
  enum UnixDatagramStaleCleanup {
    /// What a sweep removed.
    struct Summary: Equatable, Sendable {
      /// How many sockets' files were removed, not counting hidden ones.
      var socketCount = 0

      /// How many hidden sockets' files, left by a bind that never finished, were removed.
      var temporarySocketCount = 0

      /// How many markers and temporary marker files were removed.
      var markerCount = 0

      /// How many empty databases' directories were removed.
      var databaseDirectoryCount = 0

      /// How many lock files in `open-locks/` that nobody held were removed.
      var lockCount = 0
    }

    /// How long a hidden socket found dead is kept, in case its bind is still under way.
    static let defaultTemporarySocketGracePeriod: Duration = .seconds(60)

    /// Removes everything of every dead endpoint's from the coordination directory, along with
    /// the empty databases' directories and the lock files nobody holds, unless another sweep is
    /// under way.
    ///
    /// This never fails: whatever cannot be removed, or looked at, is left for the next sweep.
    ///
    /// - Parameters:
    ///   - directory: The coordination directory.
    ///   - endpointName: The name of the endpoint sweeping, whose own files are never touched.
    ///   - temporarySocketGracePeriod: How old a hidden socket found dead must be to be removed.
    ///   - didRemove: Called with the path of each socket's file and marker removed, right after
    ///     it goes. It exists for tests, to stall a sweep between two removals, and does nothing
    ///     otherwise.
    /// - Returns: What was removed, or `nil` if another sweep was under way, or the sweep's lock
    ///   could not be taken, and nothing was removed.
    @discardableResult
    static func sweep(
      directory: OrbitCoordinationDirectory,
      keeping endpointName: String,
      temporarySocketGracePeriod: Duration = Self.defaultTemporarySocketGracePeriod,
      didRemove: (_ path: String) -> Void = { _ in }
    ) -> Summary? {
      try? UnixFileLock.withExclusiveLockIfAvailable(atPath: directory.staleCleanupLock.string) {
        var sweep = Sweep(
          socketsDirectory: directory.socketsDirectory,
          databasesDirectory: directory.databasesDirectory,
          endpointName: endpointName,
          temporarySocketGracePeriod: temporarySocketGracePeriod
        )
        sweep.removeDeadSockets(didRemove: didRemove)
        sweep.removeDeadMarkers(didRemove: didRemove)
        sweep.summary.lockCount = OrbitDatabaseOpenLock.removeUnheldLocks(in: directory)
        return sweep.summary
      }
    }

    private struct Sweep {
      let socketsDirectory: FilePath
      let databasesDirectory: FilePath
      let endpointName: String
      let temporarySocketGracePeriod: Duration
      var summary = Summary()

      /// Removes the file of every socket in `v1/s/` nothing is bound to any more, and of every
      /// hidden one besides that is older than the grace period.
      mutating func removeDeadSockets(didRemove: (_ path: String) -> Void) {
        for name in FileSystem.contentsOfDirectoryIfReadable(atPath: self.socketsDirectory)
        where name.hasSuffix(".sock") {
          let path = self.socketsDirectory.appending(name)
          let isTemporary = name.hasPrefix(".")
          let endpointName = String(name.dropFirst(isTemporary ? 1 : 0).dropLast(".sock".count))
          guard endpointName != self.endpointName,
            isTemporary
              ? self.isTemporarySocketAbandoned(path) : self.isEndpointDead(endpointName),
            FileSystem.removeFile(atPath: path)
          else { continue }
          self.summary[keyPath: isTemporary ? \Summary.temporarySocketCount : \.socketCount] += 1
          didRemove(path.string)
        }
      }

      /// Removes every marker and temporary marker file of an endpoint whose socket nothing is
      /// bound to, or which has no socket at all, then every database's directory left empty.
      ///
      /// The endpoint is probed for each file, however many it left, since it may have come back
      /// since the last one went.
      ///
      /// Every directory found empty goes, not only those this emptied, since one left by an
      /// endpoint that died after withdrawing its last marker would otherwise stay forever.
      mutating func removeDeadMarkers(didRemove: (_ path: String) -> Void) {
        for coordinationKey in FileSystem.contentsOfDirectoryIfReadable(
          atPath: self.databasesDirectory
        ) {
          let directory = self.databasesDirectory.appending(coordinationKey)
          for name in FileSystem.contentsOfDirectoryIfReadable(atPath: directory) {
            guard let endpointName = Self.endpointName(ofMarker: name),
              endpointName != self.endpointName,
              self.isEndpointDead(endpointName)
            else { continue }
            let path = directory.appending(name)
            // Fails, harmlessly, on a file something else removed first.
            if FileSystem.removeFile(atPath: path) {
              self.summary.markerCount += 1
              didRemove(path.string)
            }
          }
          // Fails, harmlessly, on a directory that is not empty, or no longer there.
          if FileSystem.removeDirectory(atPath: directory) {
            self.summary.databaseDirectoryCount += 1
          }
        }
      }

      /// Whether nothing is bound at the socket's path of the endpoint named `endpointName`,
      /// including when nothing is there at all.
      ///
      /// Asked right before each removal, and never remembered: an endpoint found dead can bind
      /// its socket again an instant later, and a sweep can be stalled for any length of time
      /// between one removal and the next.
      private func isEndpointDead(_ endpointName: String) -> Bool {
        let path = self.socketsDirectory.appending("\(endpointName).sock")
        return UnixDatagramSocket.probe(path.string) == .dead
      }

      /// Whether the hidden socket at `path` was left by a bind that will never finish: nothing
      /// is bound to it, and it has been there longer than any bind takes.
      private func isTemporarySocketAbandoned(_ path: FilePath) -> Bool {
        guard UnixDatagramSocket.probe(path.string) == .dead,
          let age = FileSystem.ageOfFile(atPath: path)
        else { return false }
        return age >= self.temporarySocketGracePeriod
      }

      /// The endpoint a file in a database's directory belongs to: a marker is named after its
      /// endpoint, and a temporary one is that name with a dot before it and `.tmp` after.
      ///
      /// - Returns: The endpoint's name, or `nil` for a file no endpoint writes.
      private static func endpointName(ofMarker name: String) -> String? {
        guard name.hasPrefix(".") else { return name }
        guard name.hasSuffix(".tmp") else { return nil }
        let endpointName = name.dropFirst().dropLast(".tmp".count)
        return endpointName.isEmpty ? nil : String(endpointName)
      }
    }
  }
#endif
