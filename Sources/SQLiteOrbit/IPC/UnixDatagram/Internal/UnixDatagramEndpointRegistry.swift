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
  /// whose markers the message concerns, and a peer the endpoint finds dead is pruned from the
  /// directory.
  final class UnixDatagramEndpointRegistry: Sendable {
    private struct State {
      var watcher: UnixDirectoryWatcher?
      var peerRegions: [String: [String: OrbitDatabaseRegion]] = [:]
      /// The databases this endpoint has a marker for, by coordination key.
      var advertised: Set<String> = []
    }

    let endpointName: String
    let socketPath: String
    private let endpoint: UnixDatagramEndpoint
    private let socketsDirectory: URL
    private let databasesDirectory: URL
    private let watchesDirectories: Bool
    private let state = Lock(State())

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
    /// - Throws: A ``UnixSystemError`` if the socket cannot be created and bound, or an error if
    ///   the directory cannot be created.
    init(
      directory: URL,
      endpointName: String,
      maximumDatagramByteCount: Int,
      receiveBufferByteCount: Int,
      watchesDirectories: Bool = true
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
      self.socketsDirectory = socketsDirectory
      self.databasesDirectory = databasesDirectory
      self.watchesDirectories = watchesDirectories
    }

    /// Starts the endpoint's thread, which runs until ``shutdown()``.
    ///
    /// - Parameter receive: Receives each datagram no longer than the maximum, on the endpoint's
    ///   thread. The bytes are only valid for the duration of the call.
    func start(receive: @escaping @Sendable (Span<UInt8>) -> Void) {
      self.endpoint.start(receive: receive)
    }

    /// Withdraws every marker this endpoint wrote and removes its socket's path, so a peer that
    /// looks in the coordination directory afterwards finds nothing of it, then stops its thread.
    ///
    /// The socket itself closes once the thread has woken and let go of it, so this is safe to
    /// call from the thread itself.
    func shutdown() {
      let coordinationKeys = self.state.withLock { state in
        defer { state.advertised.removeAll() }
        return state.advertised
      }
      for coordinationKey in coordinationKeys {
        try? Self.remove(self.marker(coordinationKey))
      }
      _ = UnixPlatform.removeFile(atPath: self.socketPath)
      self.endpoint.stop()
    }

    /// Advertises `region` for a database, replacing whatever this endpoint advertised for it.
    ///
    /// When this returns, a peer that lists the database's directory finds the new region.
    func advertise(_ region: OrbitDatabaseRegion, coordinationKey: String) throws {
      let directory = try self.createDatabaseDirectory(coordinationKey: coordinationKey)
      let temporary = directory.appending(path: ".\(self.endpointName).tmp")
      try Data(UnixDatagramWireProtocol.encodeMarker(region)).write(to: temporary)
      guard
        UnixPlatform.renameFile(
          atPath: temporary.path,
          toPath: self.marker(coordinationKey).path
        )
      else { throw UnixSystemError.last("rename") }
      self.state.withLock { _ = $0.advertised.insert(coordinationKey) }
    }

    /// Removes this endpoint's marker for a database, if it has one.
    func withdraw(coordinationKey: String) throws {
      try Self.remove(self.marker(coordinationKey))
      self.state.withLock { _ = $0.advertised.remove(coordinationKey) }
    }

    /// Sends `entry` to every peer but this endpoint advertising a region its message concerns,
    /// without waiting for any of them, and prunes the peers that turn out to be dead.
    ///
    /// - Parameter entry: The message to send.
    /// - Returns: How many peers the message was sent to, how many took it, how many are owed its
    ///   region, and how many it could not be sent to at all.
    /// - Throws: An error if the coordination directory cannot be read.
    func send(_ entry: UnixDatagramWireEntry) throws -> UnixDatagramEndpoint.Delivery {
      let advertisements = try self.peerRegions(for: entry.message.databaseIdentifier)
      let delivery = self.endpoint.send(
        entry,
        to: self.peers(concernedWith: entry.message, in: advertisements),
        advertisedBy: advertisements.keys
      )
      for stale in delivery.stale {
        try? self.remove(stale.peer, coordinationKeys: stale.coordinationKeys)
      }
      return delivery
    }

    /// What each peer whose receive queue was full is owed, by endpoint name.
    var owedRegions: [String: [OrbitDatabaseIdentifier: OrbitDatabaseRegion]] {
      self.endpoint.owedRegions
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
    /// Any change forgets everything, watches included, so a database is read and watched again from
    /// scratch by the next send to it. A database whose directory cannot be watched is read on every
    /// send, which is slower and always correct.
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

    /// Removes a dead peer's socket path and its markers for the databases it was found under.
    ///
    /// - Parameters:
    ///   - peer: The peer that turned out to be dead.
    ///   - coordinationKeys: The databases it was found advertising.
    func remove(_ peer: UnixDatagramPeer, coordinationKeys: some Sequence<String>) throws {
      try Self.remove(URL(fileURLWithPath: peer.socketPath))
      for coordinationKey in coordinationKeys {
        let directory = self.databaseDirectory(coordinationKey)
        try Self.remove(directory.appending(path: peer.endpointName))
        // Left behind if the peer died between writing a marker and renaming it into place.
        try Self.remove(directory.appending(path: ".\(peer.endpointName).tmp"))
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
