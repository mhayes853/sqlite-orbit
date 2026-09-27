#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

  /// A database IPC transport backed by Unix-domain datagram sockets.
  ///
  /// Each transport binds a socket in a shared coordination directory and drops a marker file for
  /// every database it subscribes to, so peers discover each other through the filesystem without
  /// a broker process. This is the transport ``OrbitIPCDatabase`` uses.
  ///
  /// ```swift
  /// let transport = try UnixDatagramIPCTransport.shared()
  /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
  /// ```
  public final class UnixDatagramIPCTransport: OrbitIPCTransport, Sendable {
    /// Controls how a sender responds when a peer's bounded receive queue is full.
    ///
    /// A datagram socket's receive queue is finite, so a peer that stops draining it eventually
    /// refuses new messages. Nothing is ever dropped silently: the send either waits for room or
    /// throws ``PartialDeliveryError``.
    ///
    /// ```swift
    /// let coordination = UnixDatagramIPCTransport.Configuration(
    ///   backPressure: .suspend(upTo: .milliseconds(250))
    /// )
    /// ```
    public enum BackPressurePolicy: Hashable, Sendable {
      /// Fails the broadcast after attempting every currently discovered peer once.
      case fail

      /// Suspends until every backpressured peer takes the message, or this much time has elapsed.
      ///
      /// While a peer's queue is full, the messages sent to it wait in order and go out together,
      /// in as few datagrams as fit them, once it has room. Each send still waits for, and
      /// reports on, only its own message.
      case suspend(upTo: Duration)
    }

    /// Configuration for a Unix-domain datagram transport endpoint.
    ///
    /// Two transports coordinate only when they share a ``directory``, and
    /// ``UnixDatagramIPCTransport/shared(configuration:)`` reuses one endpoint per
    /// distinct configuration, so keep this value identical across the databases in a process that
    /// should share a transport.
    ///
    /// ```swift
    /// let coordination = UnixDatagramIPCTransport.Configuration(
    ///   directory: appGroupDirectory.appending(path: "coordination"),
    ///   backPressure: .suspend(upTo: .milliseconds(250))
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

      /// The configuration used by a database that does not supply one.
      ///
      /// It uses ``defaultDirectory`` and suspends a backpressured broadcast for up to 250
      /// milliseconds before reporting partial delivery.
      public static let `default` = Self(backPressure: .suspend(upTo: .milliseconds(250)))

      /// The coordination directory this process shares with its peers.
      public var directory: URL

      /// How a broadcast responds to a peer whose receive queue is full.
      public var backPressure: BackPressurePolicy

      /// The largest datagram this endpoint sends or accepts, in bytes.
      ///
      /// It also bounds each batch of messages waiting for a peer whose queue is full.
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
      ///   - backPressure: How a broadcast responds to a peer whose receive queue is full.
      ///   - maximumDatagramByteCount: The largest datagram this endpoint sends or accepts.
      ///   - receiveBufferByteCount: The size of this endpoint's socket receive buffer, which must
      ///     be at least `maximumDatagramByteCount`.
      public init(
        directory: URL = Self.defaultDirectory,
        backPressure: BackPressurePolicy,
        maximumDatagramByteCount: Int = 60 * 1024,
        receiveBufferByteCount: Int = 256 * 1024
      ) {
        self.directory = directory
        self.backPressure = backPressure
        self.maximumDatagramByteCount = maximumDatagramByteCount
        self.receiveBufferByteCount = receiveBufferByteCount
      }
    }

    /// Describes a broadcast that reached only some currently discoverable peers.
    ///
    /// The counts need not add up: a peer discovered in the coordination directory that turns out
    /// to be dead is pruned rather than counted as a failure.
    ///
    /// ```swift
    /// do {
    ///   try await transport.send(message)
    /// } catch let error as UnixDatagramIPCTransport.PartialDeliveryError {
    ///   logger.warning(
    ///     "reached \(error.deliveredPeerCount) of \(error.discoveredPeerCount) peers"
    ///   )
    /// }
    /// ```
    public struct PartialDeliveryError: Error, Hashable, Sendable {
      /// How many peers advertised, in the coordination directory, a region the message concerns.
      public let discoveredPeerCount: Int

      /// How many peers accepted the message into their receive queue.
      public let deliveredPeerCount: Int

      /// How many peers were live but did not accept the message.
      public let failedPeerCount: Int

      /// Creates an error describing a partial broadcast.
      ///
      /// - Parameters:
      ///   - discoveredPeerCount: How many peers were advertised.
      ///   - deliveredPeerCount: How many peers accepted the message.
      ///   - failedPeerCount: How many live peers did not accept it.
      public init(
        discoveredPeerCount: Int,
        deliveredPeerCount: Int,
        failedPeerCount: Int
      ) {
        self.discoveredPeerCount = discoveredPeerCount
        self.deliveredPeerCount = deliveredPeerCount
        self.failedPeerCount = failedPeerCount
      }
    }

    private let configuration: Configuration
    private let registry: UnixDatagramEndpointRegistry
    private let handlers: UnixDatagramHandlers

    /// Creates a transport endpoint in `configuration`'s coordination directory.
    ///
    /// Prefer ``shared(configuration:)``, which gives every database in a process one endpoint.
    ///
    /// ```swift
    /// let transport = try UnixDatagramIPCTransport(
    ///   configuration: .init(directory: directory, backPressure: .fail)
    /// )
    /// ```
    ///
    /// - Parameter configuration: Describes the coordination directory, back pressure, and buffer
    ///   sizes for this endpoint.
    /// - Throws: A ``UnixSystemError`` if the configuration is invalid or the socket cannot
    ///   be created and bound.
    public init(configuration: Configuration) throws {
      guard configuration.maximumDatagramByteCount > 0,
        configuration.maximumDatagramByteCount <= 65_535,
        configuration.receiveBufferByteCount >= configuration.maximumDatagramByteCount
      else {
        throw UnixSystemError.invalidArgument("invalid transport configuration")
      }
      if case .suspend(upTo: let duration) = configuration.backPressure {
        guard duration >= .zero else {
          throw UnixSystemError.invalidArgument("negative back pressure duration")
        }
      }

      let endpointName = UUID().uuidString
        .lowercased()
        .replacingOccurrences(of: "-", with: "")
        .prefix(16)
      let registry = try UnixDatagramEndpointRegistry(
        directory: configuration.directory,
        endpointName: String(endpointName),
        maximumDatagramByteCount: configuration.maximumDatagramByteCount,
        receiveBufferByteCount: configuration.receiveBufferByteCount
      )
      let handlers = UnixDatagramHandlers(registry: registry)

      self.configuration = configuration
      self.registry = registry
      self.handlers = handlers
      registry.start { bytes in
        guard let messages = try? UnixDatagramWireProtocol.decode(bytes) else { return }
        for message in messages {
          handlers.receive(message)
        }
      }
    }

    deinit {
      // Everything a peer finds this endpoint by goes now, so one that looks in the coordination
      // directory after this transport is released finds nothing of it. The descriptors
      // themselves close once the receive thread has woken and let go of the endpoint.
      self.handlers.shutdown()
      self.registry.shutdown()
    }

    /// Subscribes to messages concerning `databaseIdentifier` and `region`.
    ///
    /// This endpoint advertises, in the coordination directory, the union of the regions of its
    /// subscriptions for each database, and peers send it only the commits that union admits.
    /// The first subscription for a database makes the endpoint discoverable for it, and cancelling
    /// the last one withdraws the advertisement. Handlers run serially on the transport's receive
    /// thread, and each is only called for the commits its own region admits.
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
    /// - Throws: A ``UnixSystemError`` if the transport is closed or the coordination
    ///   directory cannot be written to.
    public func subscribe(
      to databaseIdentifier: OrbitDatabaseIdentifier,
      region: OrbitDatabaseRegion,
      onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
    ) throws -> OrbitRegionSubscription {
      let identifier = try self.handlers.add(
        databaseIdentifier: databaseIdentifier,
        region: region,
        handler: onMessage
      )
      return OrbitRegionSubscription(region: region) { [weak handlers = self.handlers] region in
        guard let handlers else { return }
        try handlers.update(
          identifier: identifier,
          databaseIdentifier: databaseIdentifier,
          region: region
        )
      } onCancel: { [weak handlers = self.handlers] in
        handlers?.remove(identifier: identifier, databaseIdentifier: databaseIdentifier)
      }
    }

    /// Broadcasts `message` to every peer advertising a region that the message concerns.
    ///
    /// Peers that have died are pruned from the coordination directory as they are discovered, so
    /// a crashed process does not fail later broadcasts. A peer whose receive queue is full is
    /// handled according to ``Configuration/backPressure``. If a commit's precise database region
    /// does not fit in one datagram, it is safely broadened to ``OrbitDatabaseRegion/fullDatabase``.
    ///
    /// ```swift
    /// try await transport.send(
    ///   .transactionDidCommit(.init(databaseIdentifier: database.id, region: .fullDatabase))
    /// )
    /// ```
    ///
    /// - Parameter message: The message to broadcast.
    /// - Throws: ``PartialDeliveryError`` when a live peer did not accept the message,
    ///   a ``UnixSystemError`` if the message cannot be encoded or sent at all, or
    ///   `CancellationError` if the task is cancelled while waiting for a backpressured peer, which
    ///   withdraws the message from every peer that had not yet accepted it.
    public func send(_ message: OrbitIPCMessage) async throws {
      let entry: UnixDatagramWireEntry
      do {
        entry = try UnixDatagramWireEntry(
          message,
          fittingIn: self.configuration.maximumDatagramByteCount
        )
      } catch UnixDatagramWireError.datagramTooLarge {
        throw UnixSystemError.messageTooLong("datagram is too large")
      }
      let suspension: Duration?
      switch self.configuration.backPressure {
      case .fail: suspension = nil
      case .suspend(upTo: let duration): suspension = duration
      }
      let delivery = try await self.registry.send(entry, suspendingUpTo: suspension)

      guard delivery.failed == 0 else {
        throw PartialDeliveryError(
          discoveredPeerCount: delivery.peerCount,
          deliveredPeerCount: delivery.delivered,
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
      self.handlers.advertisedRegion(for: databaseIdentifier)
    }

    /// How many sent messages wait in pending batches for peers whose queues are full.
    var pendingMessageCount: Int {
      self.registry.pendingMessageCount
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

  /// The handlers subscribed to this endpoint, and the markers that advertise what they cover.
  ///
  /// One marker stands for every identifier sharing a coordination key, so it advertises the union
  /// of all of their handlers' regions. It is rewritten, under the lock, whenever that union
  /// changes, so a region is advertised before the call that widened it returns, and two changes
  /// can never land in the directory in the opposite order to the one they were made in.
  private final class UnixDatagramHandlers: Sendable {
    private struct Handler: Sendable {
      var region: OrbitDatabaseRegion
      let onMessage: @Sendable (OrbitIPCMessage) -> Void
    }

    private struct State: Sendable {
      var handlers = KeyedHandlerRegistry<OrbitDatabaseIdentifier, Handler>()
      /// What each marker this endpoint wrote advertises, by coordination key.
      var advertised: [String: OrbitDatabaseRegion] = [:]
      var isShutdown = false
    }

    private let registry: UnixDatagramEndpointRegistry
    private let state = Lock(State())

    init(registry: UnixDatagramEndpointRegistry) {
      self.registry = registry
    }

    func add(
      databaseIdentifier: OrbitDatabaseIdentifier,
      region: OrbitDatabaseRegion,
      handler: @escaping @Sendable (OrbitIPCMessage) -> Void
    ) throws -> UInt64 {
      try self.state.withLock { state in
        guard !state.isShutdown else {
          throw UnixSystemError.closed("transport is closed")
        }
        let identifier = state.handlers
          .insert(Handler(region: region, onMessage: handler), for: databaseIdentifier)
          .identifier
        do {
          try self.advertise(databaseIdentifier.coordinationKey, in: &state)
        } catch {
          state.handlers.remove(identifier, for: databaseIdentifier)
          throw error
        }
        return identifier
      }
    }

    func update(
      identifier: UInt64,
      databaseIdentifier: OrbitDatabaseIdentifier,
      region: OrbitDatabaseRegion
    ) throws {
      try self.state.withLock { state in
        var previous: OrbitDatabaseRegion?
        state.handlers.update(identifier, for: databaseIdentifier) { handler in
          previous = handler.region
          handler.region = region
        }
        guard let previous else { return }
        do {
          try self.advertise(databaseIdentifier.coordinationKey, in: &state)
        } catch {
          state.handlers.update(identifier, for: databaseIdentifier) { $0.region = previous }
          throw error
        }
      }
    }

    func remove(identifier: UInt64, databaseIdentifier: OrbitDatabaseIdentifier) {
      self.state.withLock { state in
        guard state.handlers.remove(identifier, for: databaseIdentifier).didRemove else { return }
        // A marker left wider than the handlers need only costs this endpoint messages it ignores.
        try? self.advertise(databaseIdentifier.coordinationKey, in: &state)
      }
    }

    func advertisedRegion(for databaseIdentifier: OrbitDatabaseIdentifier) -> OrbitDatabaseRegion? {
      self.state.withLock { $0.advertised[databaseIdentifier.coordinationKey] }
    }

    func receive(_ message: OrbitIPCMessage) {
      let callbacks = self.state.withLock { state in
        state.handlers.handlers(for: message.databaseIdentifier)
          .filter { message.concerns($0.region) }
          .map(\.onMessage)
      }
      for callback in callbacks {
        callback(message)
      }
    }

    /// Removes every handler, and refuses new ones. The registry withdraws the markers.
    func shutdown() {
      self.state.withLock { state in
        state.isShutdown = true
        _ = state.handlers.removeAll()
        state.advertised.removeAll()
      }
    }

    /// Brings the marker for `coordinationKey` in line with the handlers that share it.
    private func advertise(_ coordinationKey: String, in state: inout State) throws {
      let handlers = state.handlers.keys
        .filter { $0.coordinationKey == coordinationKey }
        .flatMap { state.handlers.handlers(for: $0) }
      guard !handlers.isEmpty else {
        guard state.advertised[coordinationKey] != nil else { return }
        try self.registry.withdraw(coordinationKey: coordinationKey)
        state.advertised[coordinationKey] = nil
        return
      }
      let region = handlers.reduce(into: OrbitDatabaseRegion.empty) { $0.formUnion($1.region) }
      guard state.advertised[coordinationKey] != region else { return }
      try self.registry.advertise(region, coordinationKey: coordinationKey)
      state.advertised[coordinationKey] = region
    }
  }

#endif
