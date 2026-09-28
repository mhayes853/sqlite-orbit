#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

  /// A database IPC transport backed by Unix-domain datagram sockets.
  ///
  /// Each transport binds a socket in a shared coordination directory and drops a marker file for
  /// every database it subscribes to, so peers discover each other through the filesystem without
  /// a broker process. This is the transport ``OrbitIPCDatabase`` uses.
  ///
  /// A send never waits for a peer. A datagram socket's receive queue is finite, so a peer that
  /// stops reading, such as a suspended app, eventually has no room. Such a peer is owed the
  /// message's region instead: the regions of every commit it could not take are merged, one
  /// region per database, and a later commit to it joins what it is owed rather than overtaking
  /// it. Once the peer has room, the transport's thread sends it one commit per database it is
  /// owed. A peer that falls behind hears about fewer, broader commits, but never misses a change,
  /// and all that is kept for it is at most one region per database.
  ///
  /// A transport keeps its files in the coordination directory for as long as it lives. Each
  /// send and receive touches them now and then, so a system that removes temporary files nobody
  /// has used, as macOS does after three days, leaves them alone. If they are removed all the
  /// same, whether by the system, by hand, or by a peer that took this transport for dead, its
  /// thread hears about it, binds its socket again at the same path, and writes its markers
  /// again, and its peers go on sending to it, what they owed it included. A transport whose
  /// thread is held up, such as one in a suspended process, puts them back once it runs again.
  ///
  /// While they are missing, a peer that commits cannot tell this transport is there, and may
  /// leave it out of the commit, or of what it owed it. So once a transport has put back any of
  /// its files, it tells its own subscribers that every database they subscribe to may have
  /// changed entirely: each handler whose region is not empty receives a
  /// ``OrbitIPCMessage/transactionDidCommit(_:)`` with the
  /// ``OrbitDatabaseRegion/fullDatabase`` region, on the transport's thread, after peers can
  /// reach the transport again. A transport whose files are removed therefore never silently
  /// misses a commit: it either receives it, or its subscribers are told the database may have
  /// changed. Changes to the coordination directory that leave its files in place tell them
  /// nothing.
  ///
  /// ```swift
  /// let transport = try UnixDatagramIPCTransport.shared()
  /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
  /// ```
  public final class UnixDatagramIPCTransport: OrbitIPCTransport, Sendable {
    /// Configuration for a Unix-domain datagram transport endpoint.
    ///
    /// Two transports coordinate only when they share a ``directory``, and
    /// ``UnixDatagramIPCTransport/shared(configuration:)`` reuses one endpoint per
    /// distinct configuration, so keep this value identical across the databases in a process that
    /// should share a transport.
    ///
    /// ```swift
    /// let coordination = UnixDatagramIPCTransport.Configuration(
    ///   directory: appGroupDirectory.appending(path: "coordination")
    /// )
    /// let database = try OrbitIPCDatabase(
    ///   path: OrbitDatabasePath("reminders.sqlite"), coordination: coordination
    /// )
    /// ```
    public struct Configuration: Hashable, Sendable {
      /// The coordination directory used when a caller does not supply one.
      ///
      /// Processes coordinate only when they share this directory. Sandboxed applications must
      /// supply a directory inside a container both processes can reach, such as an App Group.
      public static let defaultDirectory = FileManager.default.temporaryDirectory
        .appending(path: "sqlite-orbit", directoryHint: .isDirectory)

      /// The configuration used by a database that does not supply one, which uses
      /// ``defaultDirectory``.
      public static let `default` = Self()

      /// The coordination directory this process shares with its peers.
      public var directory: URL

      /// The largest datagram this endpoint sends or accepts, in bytes.
      ///
      /// It also bounds each datagram of commits sent to a peer that was owed them.
      public var maximumDatagramByteCount: Int

      /// The size of this endpoint's socket receive buffer, in bytes.
      ///
      /// A larger buffer absorbs more messages while a process is busy, at the cost of kernel
      /// memory. It must be at least ``maximumDatagramByteCount``.
      public var receiveBufferByteCount: Int

      /// Creates a configuration.
      ///
      /// - Parameters:
      ///   - directory: The coordination directory this process shares with its peers.
      ///   - maximumDatagramByteCount: The largest datagram this endpoint sends or accepts.
      ///   - receiveBufferByteCount: The size of this endpoint's socket receive buffer, which must
      ///     be at least `maximumDatagramByteCount`.
      public init(
        directory: URL = Self.defaultDirectory,
        maximumDatagramByteCount: Int = 60 * 1024,
        receiveBufferByteCount: Int = 256 * 1024
      ) {
        self.directory = directory
        self.maximumDatagramByteCount = maximumDatagramByteCount
        self.receiveBufferByteCount = receiveBufferByteCount
      }
    }

    /// Describes a broadcast that some currently discoverable peers could not be sent at all.
    ///
    /// A peer whose receive queue is full has not failed: it is owed the message's region, and
    /// counted as deferred. The counts need not add up either way: a peer discovered in the
    /// coordination directory that turns out to be dead is pruned rather than counted.
    ///
    /// ```swift
    /// do {
    ///   try await transport.send(message)
    /// } catch let error as UnixDatagramIPCTransport.PartialDeliveryError {
    ///   logger.warning(
    ///     "could not reach \(error.failedPeerCount) of \(error.discoveredPeerCount) peers"
    ///   )
    /// }
    /// ```
    public struct PartialDeliveryError: Error, Hashable, Sendable {
      /// How many peers advertised, in the coordination directory, a region the message concerns.
      public let discoveredPeerCount: Int

      /// How many peers accepted the message into their receive queue.
      public let deliveredPeerCount: Int

      /// How many peers had no room for the message, and will be sent its region once they do.
      public let deferredPeerCount: Int

      /// How many live peers the message could not be sent to at all.
      public let failedPeerCount: Int

      /// Creates an error describing a partial broadcast.
      ///
      /// - Parameters:
      ///   - discoveredPeerCount: How many peers were advertised.
      ///   - deliveredPeerCount: How many peers accepted the message.
      ///   - deferredPeerCount: How many peers had no room for it, and are owed its region.
      ///   - failedPeerCount: How many live peers it could not be sent to at all.
      public init(
        discoveredPeerCount: Int,
        deliveredPeerCount: Int,
        deferredPeerCount: Int,
        failedPeerCount: Int
      ) {
        self.discoveredPeerCount = discoveredPeerCount
        self.deliveredPeerCount = deliveredPeerCount
        self.deferredPeerCount = deferredPeerCount
        self.failedPeerCount = failedPeerCount
      }
    }

    private typealias Handlers = KeyedHandlerRegistry<OrbitDatabaseIdentifier, OrbitIPCHandler>

    private let configuration: Configuration
    private let registry: UnixDatagramEndpointRegistry
    /// The handlers subscribed to this endpoint.
    ///
    /// A marker is rewritten under this lock whenever the union of the regions of its handlers
    /// changes, so a region is advertised before the call that widened it returns, and two changes
    /// can never land in the directory in the opposite order to the one they were made in.
    private let handlers = Lock(Handlers())

    /// Creates a transport endpoint in `configuration`'s coordination directory.
    ///
    /// Prefer ``shared(configuration:)``, which gives every database in a process one endpoint.
    ///
    /// ```swift
    /// let transport = try UnixDatagramIPCTransport(configuration: .init(directory: directory))
    /// ```
    ///
    /// - Parameter configuration: Describes the coordination directory and buffer sizes for this
    ///   endpoint.
    /// - Throws: A ``UnixSystemError`` if the configuration is invalid or the socket cannot
    ///   be created and bound.
    public convenience init(configuration: Configuration) throws {
      try self.init(
        configuration: configuration,
        refreshInterval: UnixDatagramEndpointRegistry.defaultRefreshInterval
      )
    }

    /// Creates a transport endpoint that touches its files in the coordination directory on a
    /// send or a receive `refreshInterval` after it last did.
    init(configuration: Configuration, refreshInterval: Duration) throws {
      guard configuration.maximumDatagramByteCount > 0,
        configuration.maximumDatagramByteCount <= 65_535,
        configuration.receiveBufferByteCount >= configuration.maximumDatagramByteCount
      else {
        throw UnixSystemError.invalidArgument("invalid transport configuration")
      }

      let endpointName = UUID().uuidString
        .lowercased()
        .replacingOccurrences(of: "-", with: "")
        .prefix(16)
      self.configuration = configuration
      self.registry = try UnixDatagramEndpointRegistry(
        directory: configuration.directory,
        endpointName: String(endpointName),
        maximumDatagramByteCount: configuration.maximumDatagramByteCount,
        receiveBufferByteCount: configuration.receiveBufferByteCount,
        refreshInterval: refreshInterval
      )
      // After binding, so the sweep can never take this endpoint for one of the dead it removes.
      UnixDatagramStaleCleanup.sweep(
        directory: configuration.directory,
        keeping: self.registry.endpointName
      )
      // Weakly, so that the receive thread does not keep this transport alive. If the thread ends
      // up holding the last reference, the registry is shut down from the thread, which it allows.
      // It is held only for each lookup, so a handler that lets go of the last reference releases
      // this transport there and then, not once every handler has returned.
      let deliver: @Sendable (OrbitIPCMessage) -> Void = { [weak self] message in
        for callback in self?.handlers.withLock({ $0.callbacks(for: message) }) ?? [] {
          callback(message)
        }
      }
      self.registry.start { bytes in
        for message in (try? UnixDatagramWireProtocol.decode(bytes)) ?? [] {
          deliver(message)
        }
      } onRepair: { [weak self] in
        // Peers may have left this transport out of any commit made while its files were
        // missing, so every database it has handlers for may have changed in any way.
        let databases = self?.handlers.withLock { $0.keys.sorted { $0.rawValue < $1.rawValue } }
        for databaseIdentifier in databases ?? [] {
          deliver(
            .transactionDidCommit(
              .init(databaseIdentifier: databaseIdentifier, region: .fullDatabase)
            )
          )
        }
      }
    }

    deinit {
      // Everything a peer finds this endpoint by goes now, so one that looks in the coordination
      // directory after this transport is released finds nothing of it. The descriptors
      // themselves close once the receive thread has woken and let go of the endpoint.
      self.registry.shutdown()
    }

    /// Subscribes to messages concerning `databaseIdentifier` and `region`.
    ///
    /// This endpoint advertises, in the coordination directory, the union of the regions of its
    /// subscriptions for each database, and peers send it only the commits that union admits.
    /// The first subscription for a database makes the endpoint discoverable for it, and cancelling
    /// the last one withdraws the advertisement. Handlers run serially on the transport's receive
    /// thread, and each is only called for the commits its own region admits. A handler is also
    /// sent a commit to the full database that no peer made whenever this transport has put back
    /// its files in the coordination directory, since peers may have left it out of commits made
    /// while they were missing.
    ///
    /// A widened region is advertised before ``OrbitRegionSubscription/updateRegion(_:)`` returns,
    /// so every send that starts afterwards, in any process, honors it.
    ///
    /// ```swift
    /// let subscription = try transport.subscribe(
    ///   to: database.id,
    ///   region: Reminder.databaseRegion
    /// ) { _ in refreshReminders() }
    /// ```
    ///
    /// - Parameters:
    ///   - databaseIdentifier: The database whose messages to receive.
    ///   - region: The region whose commits to receive.
    ///   - onMessage: Receives each message concerning that database and region.
    /// - Returns: A subscription that stops delivery when cancelled or released, and through which
    ///   its region can change.
    /// - Throws: A ``UnixSystemError`` if the coordination directory cannot be written to.
    public func subscribe(
      to databaseIdentifier: OrbitDatabaseIdentifier,
      region: OrbitDatabaseRegion,
      onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
    ) throws -> OrbitRegionSubscription {
      let identifier = try self.handlers.withLock { handlers in
        let identifier =
          handlers
          .insert(OrbitIPCHandler(region: region, onMessage: onMessage), for: databaseIdentifier)
          .identifier
        do {
          try self.advertise(databaseIdentifier.coordinationKey, for: handlers)
        } catch {
          handlers.remove(identifier, for: databaseIdentifier)
          throw error
        }
        return identifier
      }
      return OrbitRegionSubscription(region: region) { [weak self] region in
        try self?.update(identifier, for: databaseIdentifier, region: region)
      } onCancel: { [weak self] in
        self?.remove(identifier, for: databaseIdentifier)
      }
    }

    /// Broadcasts `message` to every peer advertising a region that the message concerns.
    ///
    /// This never waits for a peer. A peer whose receive queue is full is owed the message's region,
    /// merged with whatever else it is owed for the database, and is sent it once it has room.
    /// A peer is dead once nothing is bound at its socket's path, and a dead peer is pruned from
    /// the coordination directory, every database's markers included, as soon as a send or the
    /// transport's thread finds it, so a crashed process does not fail later broadcasts. If a
    /// commit's precise database region does not fit in one datagram, it is safely broadened to
    /// ``OrbitDatabaseRegion/fullDatabase``.
    ///
    /// ```swift
    /// try await transport.send(
    ///   .transactionDidCommit(.init(databaseIdentifier: database.id, region: .fullDatabase))
    /// )
    /// ```
    ///
    /// - Parameter message: The message to broadcast.
    /// - Throws: ``PartialDeliveryError`` when the message could not be sent to a live peer at all,
    ///   or a ``UnixSystemError`` if the message cannot be encoded or the coordination directory
    ///   cannot be read.
    public func send(_ message: OrbitIPCMessage) async throws {
      // Nothing here waits: this is `async` only because the protocol's requirement is.
      let entry: UnixDatagramWireEntry
      do {
        entry = try UnixDatagramWireEntry(
          message,
          fittingIn: self.configuration.maximumDatagramByteCount
        )
      } catch UnixDatagramWireError.datagramTooLarge {
        throw UnixSystemError.messageTooLong("datagram is too large")
      }
      let delivery = try self.registry.send(entry)

      guard delivery.failed == 0 else {
        throw PartialDeliveryError(
          discoveredPeerCount: delivery.peerCount,
          deliveredPeerCount: delivery.delivered,
          deferredPeerCount: delivery.deferred,
          failedPeerCount: delivery.failed
        )
      }
    }

    /// The peers ``send(_:)`` would send `message` to now.
    func peers(concernedWith message: OrbitIPCMessage) throws -> [UnixDatagramPeer] {
      try self.registry.peers(concernedWith: message)
    }

    /// The region this transport advertises to its peers for a database, or `nil` if it is not
    /// discoverable for that database.
    func advertisedRegion(for databaseIdentifier: OrbitDatabaseIdentifier) -> OrbitDatabaseRegion? {
      self.registry.advertisedRegion(coordinationKey: databaseIdentifier.coordinationKey)
    }

    /// What each peer whose receive queue was full is owed, by endpoint name.
    var owedRegions: [String: [OrbitDatabaseIdentifier: OrbitDatabaseRegion]] {
      self.registry.owedRegions
    }

    /// How many of this transport's files in the coordination directory it has put back since it
    /// started.
    var repairCount: Int {
      self.registry.repairCount
    }

    private func update(
      _ identifier: UInt64,
      for databaseIdentifier: OrbitDatabaseIdentifier,
      region: OrbitDatabaseRegion
    ) throws {
      try self.handlers.withLock { handlers in
        var previous: OrbitDatabaseRegion?
        handlers.update(identifier, for: databaseIdentifier) { handler in
          previous = handler.region
          handler.region = region
        }
        guard let previous else { return }
        do {
          try self.advertise(databaseIdentifier.coordinationKey, for: handlers)
        } catch {
          handlers.update(identifier, for: databaseIdentifier) { $0.region = previous }
          throw error
        }
      }
    }

    private func remove(_ identifier: UInt64, for databaseIdentifier: OrbitDatabaseIdentifier) {
      self.handlers.withLock { handlers in
        guard handlers.remove(identifier, for: databaseIdentifier).didRemove else { return }
        // A marker left wider than the handlers need only costs this endpoint messages it ignores.
        try? self.advertise(databaseIdentifier.coordinationKey, for: handlers)
      }
    }

    /// Brings the marker for `coordinationKey` in line with the handlers that share it.
    ///
    /// One marker stands for every identifier sharing a coordination key, so it advertises the
    /// union of all of their handlers' regions.
    private func advertise(_ coordinationKey: String, for handlers: Handlers) throws {
      let identifiers = handlers.keys.filter { $0.coordinationKey == coordinationKey }
      guard !identifiers.isEmpty else {
        return try self.registry.withdraw(coordinationKey: coordinationKey)
      }
      let region = identifiers.reduce(into: OrbitDatabaseRegion.empty) {
        $0.formUnion(handlers.region(for: $1))
      }
      try self.registry.advertise(region, coordinationKey: coordinationKey)
    }
  }

  extension UnixDatagramIPCTransport {
    /// Returns this process's transport for `configuration`, creating it on first use.
    ///
    /// Peers discover a process rather than an individual database, and a transport already
    /// multiplexes every database identifier it is given, so databases configured alike share one
    /// endpoint. The transport is released once its last caller releases it, so hold onto the
    /// returned value for as long as its subscriptions should keep working.
    ///
    /// ```swift
    /// let transport = try UnixDatagramIPCTransport.shared()
    /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
    /// ```
    ///
    /// - Parameter configuration: Describes the endpoint. Callers passing equal configurations
    ///   share one transport.
    /// - Returns: This process's transport for `configuration`.
    /// - Throws: A ``UnixSystemError`` if a new transport is needed and cannot be created.
    public static func shared(
      configuration: Configuration = .default
    ) throws -> UnixDatagramIPCTransport {
      try sharedTransports.withLock { transports in
        if let transport = transports[configuration]?.transport { return transport }
        let transport = try UnixDatagramIPCTransport(configuration: configuration)
        transports = transports.filter { $0.value.transport != nil }
        transports[configuration] = WeakTransport(transport: transport)
        return transport
      }
    }
  }

  private struct WeakTransport: Sendable {
    weak var transport: UnixDatagramIPCTransport?
  }

  private let sharedTransports =
    Lock<[UnixDatagramIPCTransport.Configuration: WeakTransport]>([:])

#endif
