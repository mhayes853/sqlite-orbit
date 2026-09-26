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
    /// throws ``OrbitIPCPartialDeliveryError``.
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

    private let configuration: Configuration
    private let registry: OrbitIPCEndpointRegistry
    private let endpoint: UnixDatagramEndpoint
    private let handlers: OrbitIPCHandlers

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
    /// - Throws: An ``OrbitIPCSystemError`` if the configuration is invalid or the socket cannot
    ///   be created and bound.
    public init(configuration: Configuration) throws {
      guard configuration.maximumDatagramByteCount > 0,
        configuration.maximumDatagramByteCount <= 65_535,
        configuration.receiveBufferByteCount >= configuration.maximumDatagramByteCount
      else {
        throw OrbitIPCSystemError.invalidArgument("invalid transport configuration")
      }
      if case .suspend(upTo: let duration) = configuration.backPressure {
        guard duration >= .zero else {
          throw OrbitIPCSystemError.invalidArgument("negative back pressure duration")
        }
      }

      let endpointName = UUID().uuidString
        .lowercased()
        .replacingOccurrences(of: "-", with: "")
        .prefix(16)
      let registry = try OrbitIPCEndpointRegistry(
        directory: configuration.directory,
        endpointName: String(endpointName)
      )
      let endpoint = try UnixDatagramEndpoint(
        registry: registry,
        maximumDatagramByteCount: configuration.maximumDatagramByteCount,
        receiveBufferByteCount: configuration.receiveBufferByteCount
      )
      let handlers = OrbitIPCHandlers(registry: registry)

      self.configuration = configuration
      self.registry = registry
      self.endpoint = endpoint
      self.handlers = handlers
      endpoint.start { bytes in
        guard let messages = try? OrbitIPCWireProtocol.decode(bytes) else { return }
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
      self.endpoint.removePath()
      self.endpoint.stop()
    }

    /// Subscribes to messages concerning `databaseIdentifier`.
    ///
    /// The first subscription for a database advertises this endpoint in the coordination
    /// directory, so peers can find it; cancelling the last one withdraws the advertisement.
    /// Handlers run serially on the transport's receive thread.
    ///
    /// ```swift
    /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
    /// ```
    ///
    /// - Parameters:
    ///   - databaseIdentifier: The database whose messages to receive.
    ///   - onMessage: Receives each message concerning that database.
    /// - Returns: A subscription that stops delivery when cancelled or released.
    /// - Throws: An ``OrbitIPCSystemError`` if the transport is closed or the coordination
    ///   directory cannot be written to.
    public func subscribe(
      to databaseIdentifier: OrbitDatabaseIdentifier,
      onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
    ) throws -> OrbitSubscription {
      let identifier = try self.handlers.add(
        databaseIdentifier: databaseIdentifier,
        handler: onMessage
      )
      return OrbitSubscription { [weak handlers = self.handlers] in
        handlers?.remove(identifier: identifier, databaseIdentifier: databaseIdentifier)
      }
    }

    /// Broadcasts `message` to every peer currently advertising an interest in its database.
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
    /// - Throws: ``OrbitIPCPartialDeliveryError`` when a live peer did not accept the message,
    ///   an ``OrbitIPCSystemError`` if the message cannot be encoded or sent at all, or
    ///   `CancellationError` if the task is cancelled while waiting for a backpressured peer, which
    ///   withdraws the message from every peer that had not yet accepted it.
    public func send(_ message: OrbitIPCMessage) async throws {
      let entry: OrbitIPCWireEntry
      do {
        entry = try OrbitIPCWireEntry(
          message,
          fittingIn: self.configuration.maximumDatagramByteCount
        )
      } catch OrbitIPCWireError.datagramTooLarge {
        throw OrbitIPCSystemError.messageTooLong("datagram is too large")
      }
      let peers = try self.registry.peers(databaseIdentifier: message.databaseIdentifier)
        .filter { $0.endpointName != self.registry.endpointName }
      let suspension: Duration?
      switch self.configuration.backPressure {
      case .fail: suspension = nil
      case .suspend(upTo: let duration): suspension = duration
      }
      let delivery = try await self.endpoint.send(entry, to: peers, suspendingUpTo: suspension)

      guard delivery.failed == 0 else {
        throw OrbitIPCPartialDeliveryError(
          discoveredPeerCount: peers.count,
          deliveredPeerCount: delivery.delivered,
          failedPeerCount: delivery.failed
        )
      }
    }

    /// How many sent messages wait in pending batches for peers whose queues are full.
    var pendingMessageCount: Int {
      self.endpoint.pendingMessageCount
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
    /// - Throws: An ``OrbitIPCSystemError`` if a new transport is needed and cannot be created.
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

  /// Describes a broadcast that reached only some currently discoverable peers.
  ///
  /// The counts need not add up: a peer discovered in the coordination directory that turns out to
  /// be dead is pruned rather than counted as a failure.
  ///
  /// ```swift
  /// do {
  ///   try await transport.send(message)
  /// } catch let error as OrbitIPCPartialDeliveryError {
  ///   logger.warning("reached \(error.deliveredPeerCount) of \(error.discoveredPeerCount) peers")
  /// }
  /// ```
  public struct OrbitIPCPartialDeliveryError: Error, Hashable, Sendable {
    /// How many peers the coordination directory advertised for the message's database.
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

  private final class OrbitIPCHandlers: Sendable {
    private struct State: Sendable {
      var handlers = KeyedHandlerRegistry<
        OrbitDatabaseIdentifier, @Sendable (OrbitIPCMessage) -> Void
      >()
      var isShutdown = false
    }

    private let registry: OrbitIPCEndpointRegistry
    private let state = Lock(State())

    init(registry: OrbitIPCEndpointRegistry) {
      self.registry = registry
    }

    func add(
      databaseIdentifier: OrbitDatabaseIdentifier,
      handler: @escaping @Sendable (OrbitIPCMessage) -> Void
    ) throws -> UInt64 {
      try self.state.withLock { state in
        guard !state.isShutdown else {
          throw OrbitIPCSystemError.closed("transport is closed")
        }
        // Checked before the handler is added, so this asks whether anything was subscribed
        // before it.
        if !self.isAdvertised(databaseIdentifier, in: state) {
          try self.registry.register(databaseIdentifier: databaseIdentifier)
        }
        return state.handlers.insert(handler, for: databaseIdentifier).identifier
      }
    }

    func remove(identifier: UInt64, databaseIdentifier: OrbitDatabaseIdentifier) {
      self.state.withLock { state in
        // Checked after the handler is gone, so this asks whether anything is subscribed still.
        guard state.handlers.remove(identifier, for: databaseIdentifier).isLastForKey,
          !self.isAdvertised(databaseIdentifier, in: state)
        else { return }
        try? self.registry.unregister(databaseIdentifier: databaseIdentifier)
      }
    }

    func receive(_ message: OrbitIPCMessage) {
      let callbacks = self.state.withLock { $0.handlers.handlers(for: message.databaseIdentifier) }
      for callback in callbacks {
        callback(message)
      }
    }

    func shutdown() {
      let databaseIdentifiers = self.state.withLock { state -> [OrbitDatabaseIdentifier] in
        guard !state.isShutdown else { return [] }
        state.isShutdown = true
        return state.handlers.removeAll()
      }
      // Withdrawing the same advertisement twice, as two identifiers sharing a coordination key
      // do, removes a marker file that is already gone, which the registry treats as done.
      for databaseIdentifier in databaseIdentifiers {
        try? self.registry.unregister(databaseIdentifier: databaseIdentifier)
      }
    }

    /// Whether this endpoint's advertisement for a database is one it owes to some handler.
    ///
    /// One marker stands for every identifier sharing a coordination key, so the advertisement
    /// belongs to all of their handlers rather than to any one of them.
    private func isAdvertised(
      _ databaseIdentifier: OrbitDatabaseIdentifier,
      in state: State
    ) -> Bool {
      let key = databaseIdentifier.coordinationKey
      return state.handlers.keys.contains { $0.coordinationKey == key }
    }
  }

#endif
