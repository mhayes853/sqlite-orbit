#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

  struct UnixDatagramPeer: Hashable, Sendable {
    let endpointName: String
    let socketPath: String
  }

  /// An endpoint's place in the coordination directory endpoints find each other through, and the
  /// endpoint itself.
  ///
  /// Every endpoint binds a socket in `v1/s/`, and advertises its interest in a database with a
  /// marker in `v1/d/<coordination key>/`, named after the endpoint. A marker holds the region the
  /// endpoint's subscriptions for that database cover. Markers are replaced whole by renaming a
  /// temporary file over them, and a temporary file's name starts with a dot, which no endpoint
  /// name does, so a listing never mistakes one for a marker.
  ///
  /// What peers advertise for the databases this endpoint sends to is read from their markers and
  /// kept until a watch on the coordination directory reports a change. A send goes to the peers
  /// whose markers the message concerns. A peer the endpoint finds dead, whether a send finds it or
  /// the endpoint's thread does, is pruned from the directory: its socket's path, and its marker
  /// and any temporary file it left in every database's directory, not only the ones it was found
  /// in, so nothing of it is left for any endpoint to find. A database's directory is removed
  /// once the last marker in it is.
  ///
  /// An endpoint's own files can be removed from under it while it runs: by a peer that took it
  /// for dead because its socket's path was missing, or by the system, as macOS removes temporary
  /// files nobody has used for three days. So once it is started, the endpoint keeps them. Its
  /// thread waits on a directory watch of its own, apart from the one that keeps what peers
  /// advertise, on the coordination directory, `v1/`, `v1/s/`, and the directory of every
  /// database it advertises. On any change there, the registry checks that its socket's path
  /// still names the socket it bound and that every marker it wrote is still there. If not, it
  /// watches those directories afresh, creating whichever are missing, binds a new socket at the
  /// same path and writes every missing marker again, with the region it last advertised. A peer
  /// connected to the old socket goes on sending there, which the endpoint still reads, and one
  /// that connects afterwards finds the new one. Repairing changes the watched directories
  /// itself, but a repair drains what it changed before it checks its work, so it never sets off
  /// another. Nothing waits on a timer: an endpoint whose files nothing touches costs nothing.
  ///
  /// While its files are missing, peers cannot tell the endpoint is there. A peer that finds no
  /// marker does not send it the commit, and drops what it owed it for the database, and one that
  /// finds nothing at the socket's path prunes it. So a repair that put anything back reports it,
  /// on the endpoint's thread, once the files are back, and the endpoint's owner tells its
  /// subscribers that every database it advertises may have changed entirely. After its files are
  /// removed, an endpoint therefore never silently misses a commit: it either receives it, or its
  /// subscribers are told the database may have changed, after peers can reach it again. A repair
  /// that found every file in place, as most changes to the watched directories leave it,
  /// reports nothing.
  ///
  /// To keep the system from removing its files in the first place, every send and every receive
  /// touches the endpoint's socket, its markers and the directories they are in, if it has been
  /// ``defaultRefreshInterval`` since it last did.
  final class UnixDatagramEndpointRegistry: Sendable {
    private struct State {
      var watcher: UnixDirectoryWatcher?
      var peerRegions: [String: [String: OrbitDatabaseRegion]] = [:]
    }

    /// What the registry keeps about its own files in the coordination directory.
    ///
    /// Everything that writes or removes them does so under the lock that holds this, so a repair
    /// never writes back a marker older than the one being written, or one being withdrawn.
    private struct OwnFiles {
      /// The region each marker this endpoint wrote advertises, by coordination key.
      var advertised: [String: OrbitDatabaseRegion] = [:]
      /// Whether the endpoint's thread runs, which is what hears about changes to repair.
      var isStarted = false
      var isShutDown = false
      /// The watch the endpoint's thread waits on, on the directories this endpoint's files are
      /// in.
      var watcher: UnixDirectoryWatcher?
      /// The directory at each path the watch was started on, when it was, by path. A directory
      /// removed or replaced since is no longer watched.
      var watched: [String: UnixFileIdentity] = [:]
      /// How many files a repair has put back.
      var repairCount = 0
      /// Whether a file was put back since the endpoint's thread last reported a repair.
      var hasRepaired = false
    }

    /// How long after this endpoint last touched its files a send or a receive touches them again.
    ///
    /// Far shorter than the three days after which macOS removes temporary files nobody has used,
    /// and far longer than the time between the operations it is checked on, so it costs next to
    /// nothing.
    static let defaultRefreshInterval = Duration.seconds(60 * 60)

    let endpointName: String
    let socketPath: String
    private let endpoint: UnixDatagramEndpoint
    private let coordinationDirectory: URL
    private let versionDirectory: URL
    private let socketsDirectory: URL
    private let databasesDirectory: URL
    private let watchesDirectories: Bool
    private let refreshInterval: Duration
    /// When a send or a receive next touches this endpoint's files.
    private let nextRefresh: Lock<ContinuousClock.Instant>
    private let state = Lock(State())
    private let own: Lock<OwnFiles>

    /// Creates the coordination directory's layout under `directory`, if it is not there yet, and
    /// binds this endpoint's socket in it.
    ///
    /// - Parameters:
    ///   - directory: The coordination directory.
    ///   - endpointName: The name this endpoint's socket and markers go by.
    ///   - maximumDatagramByteCount: The longest datagram to send or accept.
    ///   - receiveBufferByteCount: The size of the socket's receive buffer.
    ///   - watchesDirectories: Whether to keep what peers advertise until a directory watch says
    ///     it changed, rather than reading it again on every send.
    ///   - refreshInterval: How long after this endpoint last touched its files a send or a
    ///     receive touches them again.
    /// - Throws: A ``UnixSystemError`` if the socket cannot be created and bound, or an error if
    ///   the directory cannot be created.
    init(
      directory: URL,
      endpointName: String,
      maximumDatagramByteCount: Int,
      receiveBufferByteCount: Int,
      watchesDirectories: Bool = true,
      refreshInterval: Duration = defaultRefreshInterval
    ) throws {
      let versionDirectory = directory.appending(path: "v1", directoryHint: .isDirectory)
      let socketsDirectory = versionDirectory.appending(path: "s", directoryHint: .isDirectory)
      let databasesDirectory = versionDirectory.appending(path: "d", directoryHint: .isDirectory)
      for directory in [socketsDirectory, databasesDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      let socketPath = socketsDirectory.appending(path: "\(endpointName).sock").path
      self.endpoint = try UnixDatagramEndpoint(
        socketPath: socketPath,
        maximumDatagramByteCount: maximumDatagramByteCount,
        receiveBufferByteCount: receiveBufferByteCount
      )
      self.endpointName = endpointName
      self.socketPath = socketPath
      self.coordinationDirectory = directory
      self.versionDirectory = versionDirectory
      self.socketsDirectory = socketsDirectory
      self.databasesDirectory = databasesDirectory
      self.watchesDirectories = watchesDirectories
      self.refreshInterval = refreshInterval
      self.own = Lock(OwnFiles())
      self.nextRefresh = Lock(.now.advanced(by: refreshInterval))
    }

    /// Starts the endpoint's thread, which runs until ``shutdown()``, and from then on keeps this
    /// endpoint's files in the coordination directory, putting back any that are removed.
    ///
    /// - Parameters:
    ///   - receive: Receives each datagram no longer than the maximum, on the endpoint's thread.
    ///     The bytes are only valid for the duration of the call.
    ///   - onRepair: Called on the endpoint's thread, without any lock held, after a repair put
    ///     back any of this endpoint's files, on whichever thread the repair ran. Peers may have
    ///     left out, while the files were missing, commits to any database this endpoint
    ///     advertises. Repairs that run before it is called are reported by the one call.
    func start(
      receive: @escaping @Sendable (Span<UInt8>) -> Void,
      onRepair: @escaping @Sendable () -> Void = {}
    ) {
      // Weakly, so that the thread, which the endpoint keeps until it is stopped, keeps nothing
      // else alive.
      self.endpoint.start(
        receive: { [weak self] bytes in
          self?.refreshIfDue()
          receive(bytes)
        },
        onStalePeer: { [weak self] peer in
          self?.prune(peer)
        },
        onChange: { [weak self] in
          if self?.repairIfChanged() == true {
            onRepair()
          }
        }
      )
      self.own.withLock { own in
        own.isStarted = true
        self.repair(&own)
      }
    }

    /// Withdraws every marker this endpoint wrote and removes its socket's path, so a peer that
    /// looks in the coordination directory afterwards finds nothing of it, then stops its thread.
    ///
    /// Nothing is put back once this has begun. The socket itself closes once the thread has
    /// woken and let go of it, so this is safe to call from the thread itself.
    func shutdown() {
      let watcher = self.own.withLock { own in
        own.isShutDown = true
        for coordinationKey in own.advertised.keys {
          try? Self.remove(self.marker(coordinationKey))
          self.reclaimDatabaseDirectory(coordinationKey)
        }
        own.advertised.removeAll()
        _ = UnixPlatform.removeFile(atPath: self.socketPath)
        return own.watcher.take()
      }
      // The thread stops waiting on the watch before it closes.
      withExtendedLifetime(watcher) {
        try? self.endpoint.waitForChanges(on: nil)
      }
      self.endpoint.stop()
    }

    /// Advertises `region` for a database, replacing whatever this endpoint advertised for it.
    ///
    /// When this returns, a peer that lists the database's directory finds the new region. The
    /// region it already advertises is not written again.
    func advertise(_ region: OrbitDatabaseRegion, coordinationKey: String) throws {
      try self.own.withLock { own in
        guard own.advertised[coordinationKey] != region else { return }
        // A marker removed since it was written is put back here rather than by a repair, which
        // must be reported all the same.
        let isMissing =
          own.advertised[coordinationKey] != nil
          && UnixPlatform.fileIdentity(atPath: self.marker(coordinationKey).path) == nil
        try self.writeMarker(region, coordinationKey: coordinationKey)
        if isMissing {
          self.notePutBack(&own)
        }
        guard own.advertised.updateValue(region, forKey: coordinationKey) == nil else { return }
        // The database's directory holds a file of this endpoint's now, so it is watched too.
        self.repair(&own)
      }
    }

    /// Writes this endpoint's marker for a database.
    private func writeMarker(_ region: OrbitDatabaseRegion, coordinationKey: String) throws {
      let marker = Data(UnixDatagramWireProtocol.encodeMarker(region))
      // Another endpoint reclaims the database's directory once it is empty, which it is between
      // being created here and the temporary file landing in it. Writing that file then fails for
      // want of the directory, which the next attempt creates again.
      for attempt in 1...Self.maximumAdvertiseAttemptCount {
        do {
          // Renamed over the marker, so a peer never reads one half written.
          let directory = try self.createDatabaseDirectory(coordinationKey: coordinationKey)
          let temporary = directory.appending(path: ".\(self.endpointName).tmp")
          try marker.write(to: temporary)
          guard
            UnixPlatform.renameFile(
              atPath: temporary.path,
              toPath: self.marker(coordinationKey).path
            )
          else { throw UnixSystemError.last("rename") }
          return
        } catch let error
          where attempt < Self.maximumAdvertiseAttemptCount && Self.isMissingFile(error)
        {
          continue
        }
      }
    }

    /// How many times ``advertise(_:coordinationKey:)`` writes a marker whose directory keeps
    /// disappearing before it gives up.
    private static let maximumAdvertiseAttemptCount = 3

    private static func isMissingFile(_ error: any Error) -> Bool {
      switch error {
      case CocoaError.fileNoSuchFile:
        true
      case let error as UnixSystemError:
        error.code == UnixPlatform.ErrorCode.noSuchFile
      default:
        false
      }
    }

    /// Removes this endpoint's marker for a database, if it has one.
    func withdraw(coordinationKey: String) throws {
      try self.own.withLock { own in
        guard own.advertised[coordinationKey] != nil else { return }
        try Self.remove(self.marker(coordinationKey))
        own.advertised[coordinationKey] = nil
        self.reclaimDatabaseDirectory(coordinationKey)
        // Its directory holds no file of this endpoint's any more, so it is no longer watched.
        self.repair(&own)
      }
    }

    /// Sends `entry` to every peer but this endpoint advertising a region its message concerns,
    /// without waiting for any of them, and prunes the peers that turn out to be dead.
    ///
    /// - Parameter entry: The message to send.
    /// - Returns: How many peers the message was sent to, how many took it, how many are owed its
    ///   region, and how many it could not be sent to at all.
    /// - Throws: An error if the coordination directory cannot be read.
    func send(_ entry: UnixDatagramWireEntry) throws -> UnixDatagramEndpoint.Delivery {
      self.refreshIfDue()
      let advertisements = try self.peerRegions(for: entry.message.databaseIdentifier)
      let delivery = self.endpoint.send(
        entry,
        to: self.peers(concernedWith: entry.message, in: advertisements),
        advertisedBy: advertisements.keys
      )
      for peer in delivery.stale {
        self.prune(peer)
      }
      return delivery
    }

    /// What each peer whose receive queue was full is owed, by endpoint name.
    var owedRegions: [String: [OrbitDatabaseIdentifier: OrbitDatabaseRegion]] {
      self.endpoint.owedRegions
    }

    /// The region this endpoint advertises for a database, or `nil` if it advertises nothing.
    func advertisedRegion(coordinationKey: String) -> OrbitDatabaseRegion? {
      self.own.withLock { $0.advertised[coordinationKey] }
    }

    /// How many of this endpoint's files have been put back since it started.
    var repairCount: Int {
      self.own.withLock { $0.repairCount }
    }

    /// The peers ``send(_:)`` would send `message` to now.
    func peers(concernedWith message: OrbitIPCMessage) throws -> [UnixDatagramPeer] {
      try self.peers(concernedWith: message, in: self.peerRegions(for: message.databaseIdentifier))
    }

    /// Creates the directory a database's markers go in, if it is not there yet.
    ///
    /// - Returns: The directory.
    func createDatabaseDirectory(coordinationKey: String) throws -> URL {
      let directory = self.databaseDirectory(coordinationKey)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }

    func peers(databaseIdentifier: OrbitDatabaseIdentifier) throws -> [UnixDatagramPeer] {
      try self.advertisements(coordinationKey: databaseIdentifier.coordinationKey).keys
        .map(self.peer(named:))
    }

    /// What every endpoint advertising a database advertises now.
    ///
    /// The watch is drained on the sending thread, under the registry's lock, before what it kept
    /// is used. A peer widening its region renames its new marker into place before it relies on
    /// the wider region, so by the time any commit it must hear about can start, the kernel has
    /// already queued that rename, and the send that commit makes cannot miss it. A watch drained
    /// on some other thread could still be behind.
    ///
    /// Any change forgets everything read, watches included, so a database is read and watched
    /// again from scratch by the next send to it, which re-creates its directory if it was removed.
    /// A database whose directory cannot be watched is read on every send, which is slower and
    /// always correct.
    ///
    /// - Returns: The region each endpoint's subscriptions cover, by endpoint name.
    func peerRegions(
      for databaseIdentifier: OrbitDatabaseIdentifier
    ) throws -> [String: OrbitDatabaseRegion] {
      let coordinationKey = databaseIdentifier.coordinationKey
      return try self.state.withLock { state in
        if state.watcher?.drainChanges() == true {
          // What this endpoint advertises is its own, and no change of anyone else's affects it.
          state.watcher = nil
          state.peerRegions.removeAll()
        }
        if let peerRegions = state.peerRegions[coordinationKey] {
          return peerRegions
        }
        if state.watcher == nil, self.watchesDirectories {
          state.watcher = try? UnixDirectoryWatcher()
        }
        // Created up front so there is a directory to watch, and watched before it is read, so a
        // change made while reading it is reported.
        let directory = try self.createDatabaseDirectory(coordinationKey: coordinationKey)
        let isWatched = (try? state.watcher?.watch(directory.path)) != nil
        let peerRegions = try self.advertisements(coordinationKey: coordinationKey)
        if isWatched {
          state.peerRegions[coordinationKey] = peerRegions
        }
        return peerRegions
      }
    }

    func peer(named endpointName: String) -> UnixDatagramPeer {
      UnixDatagramPeer(
        endpointName: endpointName,
        socketPath: self.socketsDirectory.appending(path: "\(endpointName).sock").path
      )
    }

    /// Removes everything of a dead peer's from the coordination directory: its socket's path, and
    /// its marker and temporary file in every database's directory.
    ///
    /// Every database is looked in, not only the ones the peer was found advertising, because
    /// nothing else would ever remove the markers for databases this endpoint does not send to.
    /// The socket's path goes first, so if this is cut short, whatever marker is left still leads
    /// the next endpoint to find the peer dead and prune it.
    ///
    /// - Parameter peer: The peer that turned out to be dead.
    func prune(_ peer: UnixDatagramPeer) {
      _ = UnixPlatform.removeFile(atPath: peer.socketPath)
      let coordinationKeys =
        (try? FileManager.default.contentsOfDirectory(atPath: self.databasesDirectory.path)) ?? []
      for coordinationKey in coordinationKeys {
        let directory = self.databaseDirectory(coordinationKey)
        let removedMarker = UnixPlatform.removeFile(
          atPath: directory.appending(path: peer.endpointName).path
        )
        // Left behind if the peer died between writing a marker and renaming it into place.
        let removedTemporary = UnixPlatform.removeFile(
          atPath: directory.appending(path: ".\(peer.endpointName).tmp").path
        )
        if removedMarker || removedTemporary {
          self.reclaimDatabaseDirectory(coordinationKey)
        }
      }
    }

    /// Reads every marker for a database.
    ///
    /// A marker that cannot be read or decoded, or that is empty, advertises the full database,
    /// which is never wrong: it only costs its endpoint messages it ignores.
    ///
    /// - Returns: The region each advertising endpoint's subscriptions cover, by endpoint name.
    private func advertisements(coordinationKey: String) throws -> [String: OrbitDatabaseRegion] {
      let directory = self.databaseDirectory(coordinationKey)
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      } catch CocoaError.fileReadNoSuchFile {
        return [:]
      }
      var advertisements: [String: OrbitDatabaseRegion] = [:]
      for name in names where !name.hasPrefix(".") {
        let marker: Data
        do {
          marker = try Data(contentsOf: directory.appending(path: name))
        } catch CocoaError.fileReadNoSuchFile {
          // Removed since the listing, by an endpoint that stopped advertising.
          continue
        } catch {
          marker = Data()
        }
        advertisements[name] =
          (try? [UInt8](marker)
            .withUnsafeBufferPointer {
              try UnixDatagramWireProtocol.decodeMarker(Span(_unsafeElements: $0))
            }) ?? .fullDatabase
      }
      return advertisements
    }

    /// Every peer but this endpoint whose advertised region `message` concerns.
    private func peers(
      concernedWith message: OrbitIPCMessage,
      in advertisements: [String: OrbitDatabaseRegion]
    ) -> [UnixDatagramPeer] {
      advertisements.compactMap { name, region in
        guard name != self.endpointName, message.concerns(region) else { return nil }
        return self.peer(named: name)
      }
    }

    private func marker(_ coordinationKey: String) -> URL {
      self.databaseDirectory(coordinationKey).appending(path: self.endpointName)
    }

    /// Removes a database's directory if nothing is left in it, now that this endpoint has removed
    /// a marker from it, so the coordination directory does not keep a directory for every
    /// database any endpoint ever advertised.
    ///
    /// A directory that holds anything must be left alone, because what it holds may be a marker
    /// another endpoint has just written, so this asks the system to remove it only if it is
    /// empty, which it checks and does in one step. A directory that is not empty, or already
    /// gone, stays as it is. An endpoint that finds the directory gone creates it again, both to
    /// advertise and to send, and retries a marker whose directory this removed from under it.
    private func reclaimDatabaseDirectory(_ coordinationKey: String) {
      _ = UnixPlatform.removeDirectory(atPath: self.databaseDirectory(coordinationKey).path)
    }

    // MARK: - Keeping This Endpoint's Files

    /// Repairs this endpoint's files if the watch the thread waits on reports a change, and any
    /// of them is not as this endpoint left it.
    ///
    /// Most changes are other endpoints' files coming and going beside this one's, which only
    /// cost a look at this endpoint's own.
    ///
    /// - Returns: Whether this, or a repair on another thread since the last call, put back any
    ///   file.
    private func repairIfChanged() -> Bool {
      self.own.withLock { own in
        if own.watcher?.drainChanges() == true, !self.isIntact(own) {
          self.repair(&own)
        }
        defer { own.hasRepaired = false }
        return own.hasRepaired && !own.isShutDown
      }
    }

    /// Counts a file put back, and has the endpoint's thread report it, which it does even if
    /// this runs on some other thread.
    private func notePutBack(_ own: inout OwnFiles) {
      own.repairCount += 1
      own.hasRepaired = true
      self.endpoint.requestChange()
    }

    /// Whether this endpoint's socket's path still names the socket it bound, every marker it
    /// wrote is still there, and every directory its watch was started on is still the one it was
    /// started on.
    private func isIntact(_ own: OwnFiles) -> Bool {
      UnixPlatform.fileIdentity(atPath: self.socketPath) == self.endpoint.boundFile
        && own.advertised.keys.allSatisfy {
          UnixPlatform.fileIdentity(atPath: self.marker($0).path) != nil
        }
        && own.watched.allSatisfy { UnixPlatform.fileIdentity(atPath: $0.key) == $0.value }
    }

    /// Starts a new watch on the directories this endpoint's files are in, creating whichever are
    /// missing, then puts back whichever of its files is missing: its socket, bound again at the
    /// same path, and each marker, with the region it last advertised.
    ///
    /// The watch starts first, so a change made while this runs is heard about. What this changes
    /// itself is then drained from the watch, so a repair never sets off another, and the files
    /// are checked once more: something that changed them meanwhile has this start over, a few
    /// times at most, after which the next change the thread hears about tries again.
    private func repair(_ own: inout OwnFiles) {
      guard own.isStarted, !own.isShutDown else { return }
      for _ in 0..<Self.maximumRepairAttemptCount {
        let watcher = try? UnixDirectoryWatcher()
        var watched: [String: UnixFileIdentity] = [:]
        let directories =
          [self.coordinationDirectory, self.versionDirectory, self.socketsDirectory]
          + own.advertised.keys.sorted().map(self.databaseDirectory)
        for directory in directories {
          try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          // Looked up before the watch starts, so a directory replaced in between is found
          // replaced by the next check, rather than taken for the one watched.
          guard let watcher, let identity = UnixPlatform.fileIdentity(atPath: directory.path),
            (try? watcher.watch(directory.path)) != nil
          else { continue }
          watched[directory.path] = identity
        }

        if UnixPlatform.fileIdentity(atPath: self.socketPath) != self.endpoint.boundFile,
          (try? self.endpoint.rebind()) != nil
        {
          self.notePutBack(&own)
        }
        for (coordinationKey, region) in own.advertised
        where UnixPlatform.fileIdentity(atPath: self.marker(coordinationKey).path) == nil {
          if (try? self.writeMarker(region, coordinationKey: coordinationKey)) != nil {
            self.notePutBack(&own)
          }
        }

        // The watch this replaces closes once the thread no longer waits on it.
        if (try? self.endpoint.waitForChanges(on: watcher?.descriptor)) != nil {
          own.watcher = watcher
          own.watched = watched
        }
        _ = own.watcher?.drainChanges()
        if self.isIntact(own) { return }
      }
    }

    /// How many times in a row ``repair(_:)`` starts over when this endpoint's files keep changing
    /// under it.
    private static let maximumRepairAttemptCount = 3

    /// Touches this endpoint's socket, its markers and the directories they are in, if it has
    /// been ``refreshInterval`` since it last did, so a system that removes temporary files nobody
    /// has used for a while leaves them alone for as long as the endpoint is in use.
    ///
    /// It is called on every send and every receive, and costs one look at the clock unless it
    /// is due. A file that is gone is not created again here, which is left to the repair its
    /// removal sets off.
    private func refreshIfDue() {
      // Apart from the lock on this endpoint's files, so a send that is not due never waits
      // behind a repair's filesystem work.
      let isDue = self.nextRefresh.withLock { next in
        let now = ContinuousClock.now
        guard now >= next else { return false }
        next = now.advanced(by: self.refreshInterval)
        return true
      }
      guard isDue else { return }
      self.own.withLock { own in
        var paths = [self.socketPath, self.socketsDirectory.path]
        for coordinationKey in own.advertised.keys {
          paths.append(self.marker(coordinationKey).path)
          paths.append(self.databaseDirectory(coordinationKey).path)
        }
        for path in paths {
          _ = UnixPlatform.touchFile(atPath: path)
        }
      }
    }

    private static func remove(_ url: URL) throws {
      do {
        try FileManager.default.removeItem(at: url)
      } catch CocoaError.fileNoSuchFile {
      }
    }

    private func databaseDirectory(_ coordinationKey: String) -> URL {
      self.databasesDirectory.appending(path: coordinationKey, directoryHint: .isDirectory)
    }
  }
#endif
