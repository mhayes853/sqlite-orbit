#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

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
  ///
  /// Sweeps are one at a time, under a lock no sweep waits for: whoever finds it held skips its
  /// sweep, as the holder is removing the same things.
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
    /// - Returns: What was removed, or `nil` if another sweep was under way, or the sweep's lock
    ///   could not be taken, and nothing was removed.
    @discardableResult
    static func sweep(
      directory: URL,
      keeping endpointName: String,
      temporarySocketGracePeriod: Duration = Self.defaultTemporarySocketGracePeriod
    ) -> Summary? {
      let versionDirectory = directory.appending(path: "v1", directoryHint: .isDirectory)
      let lock = versionDirectory.appending(path: "cleanup-stale.lock").path
      let summary = try? UnixFileLock.withExclusiveLockIfAvailable(atPath: lock) {
        var sweep = Sweep(
          socketsDirectory: versionDirectory.appending(path: "s", directoryHint: .isDirectory),
          databasesDirectory: versionDirectory.appending(path: "d", directoryHint: .isDirectory),
          endpointName: endpointName,
          temporarySocketGracePeriod: temporarySocketGracePeriod
        )
        sweep.removeDeadSockets()
        sweep.removeDeadMarkers()
        sweep.summary.lockCount = OrbitDatabaseOpenLock.removeUnheldLocks(directory: directory)
        return sweep.summary
      }
      return summary ?? nil
    }

    private struct Sweep {
      let socketsDirectory: URL
      let databasesDirectory: URL
      let endpointName: String
      let temporarySocketGracePeriod: Duration
      var summary = Summary()

      /// Whether each endpoint looked at is dead, by name, so each is probed once however many
      /// files it left.
      var isDead: [String: Bool] = [:]

      /// Removes the file of every socket in `v1/s/` nothing is bound to any more, and of every
      /// hidden one besides that is older than the grace period.
      mutating func removeDeadSockets() {
        for name in Self.contents(of: self.socketsDirectory) where name.hasSuffix(".sock") {
          let path = self.socketsDirectory.appending(path: name).path
          let isTemporary = name.hasPrefix(".")
          let endpointName = String(name.dropFirst(isTemporary ? 1 : 0).dropLast(".sock".count))
          guard endpointName != self.endpointName,
            isTemporary
              ? self.isTemporarySocketAbandoned(path) : self.isEndpointDead(endpointName),
            UnixPlatform.removeFile(atPath: path)
          else { continue }
          self.summary[keyPath: isTemporary ? \Summary.temporarySocketCount : \.socketCount] += 1
        }
      }

      /// Removes every marker and temporary marker file of an endpoint whose socket nothing is
      /// bound to, or which has no socket at all, then every database's directory left empty.
      ///
      /// Every directory found empty goes, not only those this emptied, since one left by an
      /// endpoint that died after withdrawing its last marker would otherwise stay forever.
      mutating func removeDeadMarkers() {
        for coordinationKey in Self.contents(of: self.databasesDirectory) {
          let directory = self.databasesDirectory.appending(
            path: coordinationKey,
            directoryHint: .isDirectory
          )
          for name in Self.contents(of: directory) {
            guard let endpointName = Self.endpointName(ofMarker: name),
              endpointName != self.endpointName,
              self.isEndpointDead(endpointName)
            else { continue }
            // Fails, harmlessly, on a file something else removed first.
            if UnixPlatform.removeFile(atPath: directory.appending(path: name).path) {
              self.summary.markerCount += 1
            }
          }
          // Fails, harmlessly, on a directory that is not empty, or no longer there.
          if UnixPlatform.removeDirectory(atPath: directory.path) {
            self.summary.databaseDirectoryCount += 1
          }
        }
      }

      /// Whether nothing is bound at the socket's path of the endpoint named `endpointName`,
      /// including when nothing is there at all.
      private mutating func isEndpointDead(_ endpointName: String) -> Bool {
        if let isDead = self.isDead[endpointName] { return isDead }
        let path = self.socketsDirectory.appending(path: "\(endpointName).sock").path
        let isDead = UnixDatagramSocket.probe(path) == .dead
        self.isDead[endpointName] = isDead
        return isDead
      }

      /// Whether the hidden socket at `path` was left by a bind that will never finish: nothing
      /// is bound to it, and it has been there longer than any bind takes.
      private func isTemporarySocketAbandoned(_ path: String) -> Bool {
        guard UnixDatagramSocket.probe(path) == .dead,
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let modified = attributes[.modificationDate] as? Date
        else { return false }
        return Date.now.timeIntervalSince(modified) >= self.temporarySocketGracePeriod / .seconds(1)
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

      /// The names of what is in `directory`, or none if it cannot be listed, as when it is gone.
      private static func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      }
    }
  }
#endif
