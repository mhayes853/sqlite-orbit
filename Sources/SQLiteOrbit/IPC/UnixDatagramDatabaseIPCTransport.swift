#if canImport(Darwin) || canImport(Glibc)
  import Dispatch
  import Foundation
  import Synchronization

  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif

  /// A database IPC transport backed by Unix-domain datagram sockets.
  ///
  /// Each transport binds a socket in a shared coordination directory and drops a marker file for
  /// every database it subscribes to, so peers discover each other through the filesystem without
  /// a broker process. This is the transport ``OrbitDatabase`` uses.
  ///
  /// ```swift
  /// let transport = try UnixDatagramDatabaseIPCTransport.shared()
  /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
  /// ```
  public final class UnixDatagramDatabaseIPCTransport: DatabaseIPCTransport, Sendable {
    /// Controls how a sender responds when a peer's bounded receive queue is full.
    ///
    /// A datagram socket's receive queue is finite, so a peer that stops draining it eventually
    /// refuses new messages. Nothing is ever dropped silently: the send either waits for room or
    /// throws ``DatabaseIPCPartialDeliveryError``.
    ///
    /// ```swift
    /// let coordination = UnixDatagramDatabaseIPCTransport.Configuration(
    ///   backPressure: .suspend(upTo: .milliseconds(250))
    /// )
    /// ```
    public enum BackPressurePolicy: Hashable, Sendable {
      /// Fails the broadcast after attempting every currently discovered peer once.
      case fail

      /// Suspends and retries backpressured peers until this much time has elapsed.
      case suspend(upTo: Duration)
    }

    /// Configuration for a Unix-domain datagram transport endpoint.
    ///
    /// Two transports coordinate only when they share a ``directory``, and
    /// ``UnixDatagramDatabaseIPCTransport/shared(configuration:)`` reuses one endpoint per
    /// distinct configuration, so keep this value identical across the databases in a process that
    /// should share a transport.
    ///
    /// ```swift
    /// let coordination = UnixDatagramDatabaseIPCTransport.Configuration(
    ///   directory: appGroupDirectory.appending(path: "coordination"),
    ///   backPressure: .suspend(upTo: .milliseconds(250))
    /// )
    /// let database = try OrbitDatabase(
    ///   path: DatabasePath("reminders.sqlite"), coordination: coordination
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
    private let registry: DatabaseIPCEndpointRegistry
    private let socket: UnixDatagramSocket
    private let handlers: DatabaseIPCHandlers
    private let receiver: Mutex<DispatchSourceRead?>

    /// Creates a transport endpoint in `configuration`'s coordination directory.
    ///
    /// Prefer ``shared(configuration:)``, which gives every database in a process one endpoint.
    ///
    /// ```swift
    /// let transport = try UnixDatagramDatabaseIPCTransport(
    ///   configuration: .init(directory: directory, backPressure: .fail)
    /// )
    /// ```
    ///
    /// - Parameter configuration: Describes the coordination directory, back pressure, and buffer
    ///   sizes for this endpoint.
    /// - Throws: A ``DatabaseIPCSystemError`` if the configuration is invalid or the socket cannot
    ///   be created and bound.
    public init(configuration: Configuration) throws {
      guard configuration.maximumDatagramByteCount > 0,
        configuration.maximumDatagramByteCount <= 65_535,
        configuration.receiveBufferByteCount >= configuration.maximumDatagramByteCount
      else {
        throw DatabaseIPCSystemError(operation: "invalid transport configuration", code: EINVAL)
      }
      if case .suspend(upTo: let duration) = configuration.backPressure {
        guard duration >= .zero else {
          throw DatabaseIPCSystemError(operation: "negative back pressure duration", code: EINVAL)
        }
      }

      let endpointName = UUID().uuidString
        .lowercased()
        .replacingOccurrences(of: "-", with: "")
        .prefix(16)
      let registry = try DatabaseIPCEndpointRegistry(
        directory: configuration.directory,
        endpointName: String(endpointName)
      )
      let socket = try UnixDatagramSocket(
        path: registry.socketPath,
        receiveBufferByteCount: configuration.receiveBufferByteCount
      )
      let handlers = DatabaseIPCHandlers(registry: registry)
      let receiver = DispatchSource.makeReadSource(
        fileDescriptor: socket.descriptor,
        queue: DispatchQueue(label: "SQLiteOrbit.UnixDatagramReceiver")
      )
      receiver.setEventHandler {
        while let bytes = try? socket.receive(
          maximumByteCount: configuration.maximumDatagramByteCount
        ) {
          guard bytes.count <= configuration.maximumDatagramByteCount,
            let message = try? bytes.withUnsafeBufferPointer({
              try DatabaseIPCWireProtocol.decode(Span(_unsafeElements: $0))
            })
          else { continue }
          handlers.receive(message)
        }
      }
      self.configuration = configuration
      self.registry = registry
      self.socket = socket
      self.handlers = handlers
      receiver.resume()
      self.receiver = Mutex(receiver)
    }

    deinit {
      self.handlers.shutdown()
      self.receiver.withLock {
        $0?.cancel()
        $0 = nil
      }
      self.socket.close()
    }

    /// Subscribes to messages concerning `databaseIdentifier`.
    ///
    /// The first subscription for a database advertises this endpoint in the coordination
    /// directory, so peers can find it; cancelling the last one withdraws the advertisement.
    /// Handlers run serially on the transport's receive queue.
    ///
    /// ```swift
    /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
    /// ```
    ///
    /// - Parameters:
    ///   - databaseIdentifier: The database whose messages to receive.
    ///   - onMessage: Receives each message concerning that database.
    /// - Returns: A subscription that stops delivery when cancelled or released.
    /// - Throws: A ``DatabaseIPCSystemError`` if the transport is closed or the coordination
    ///   directory cannot be written to.
    public func subscribe(
      to databaseIdentifier: DatabaseIdentifier,
      onMessage: @escaping @Sendable (DatabaseIPCMessage) -> Void
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
    /// handled according to ``Configuration/backPressure``.
    ///
    /// ```swift
    /// try await transport.send(.transactionDidCommit(.init(databaseIdentifier: database.id)))
    /// ```
    ///
    /// - Parameter message: The message to broadcast.
    /// - Throws: ``DatabaseIPCPartialDeliveryError`` when a live peer did not accept the message,
    ///   or a ``DatabaseIPCSystemError`` if the message cannot be encoded or sent at all.
    public func send(_ message: DatabaseIPCMessage) async throws {
      let bytes = try DatabaseIPCWireProtocol.encode(message)
      guard bytes.count <= self.configuration.maximumDatagramByteCount else {
        throw DatabaseIPCSystemError(operation: "datagram is too large", code: EMSGSIZE)
      }
      let peers = try self.registry.peers(databaseIdentifier: message.databaseIdentifier)
        .filter { $0.endpointName != self.registry.endpointName }
      var result = self.attempt(bytes, to: peers, databaseIdentifier: message.databaseIdentifier)

      switch self.configuration.backPressure {
      case .fail:
        result.failed += result.pending.count
      case .suspend(upTo: let duration):
        let retry = try await self.retry(
          bytes,
          to: result.pending,
          databaseIdentifier: message.databaseIdentifier,
          upTo: duration
        )
        result.delivered += retry.delivered
        result.failed += retry.failed
      }

      guard result.failed == 0 else {
        throw DatabaseIPCPartialDeliveryError(
          discoveredPeerCount: peers.count,
          deliveredPeerCount: result.delivered,
          failedPeerCount: result.failed
        )
      }
    }

    private func attempt(
      _ bytes: [UInt8],
      to peers: [DatabaseIPCPeer],
      databaseIdentifier: DatabaseIdentifier
    ) -> (delivered: Int, failed: Int, pending: [DatabaseIPCPeer]) {
      var result = (delivered: 0, failed: 0, pending: [DatabaseIPCPeer]())
      for peer in peers {
        do {
          if try self.socket.send(bytes, to: peer.socketPath) {
            result.delivered += 1
          } else {
            result.pending.append(peer)
          }
        } catch let error as DatabaseIPCSystemError where Self.isStaleEndpointError(error.code) {
          try? self.registry.remove(peer, databaseIdentifier: databaseIdentifier)
        } catch {
          result.failed += 1
        }
      }
      return result
    }

    private func retry(
      _ bytes: [UInt8],
      to peers: [DatabaseIPCPeer],
      databaseIdentifier: DatabaseIdentifier,
      upTo duration: Duration
    ) async throws -> (delivered: Int, failed: Int) {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: duration)
      var pendingPeers = peers
      var result = (delivered: 0, failed: 0)
      var retryDelay = Duration.milliseconds(1)

      while !pendingPeers.isEmpty, clock.now < deadline {
        // AF_UNIX datagrams have no destination-specific writable event, so retry with a bounded
        // backoff rather than spinning when a particular peer's receive queue is full. The attempt
        // that lands exactly on the deadline still happens: the budget is time spent waiting.
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: retryDelay)))
        retryDelay = min(retryDelay * 2, .milliseconds(16))
        let attempt = self.attempt(bytes, to: pendingPeers, databaseIdentifier: databaseIdentifier)
        result.delivered += attempt.delivered
        result.failed += attempt.failed
        pendingPeers = attempt.pending
      }
      return (result.delivered, result.failed + pendingPeers.count)
    }

    private static func isStaleEndpointError(_ code: Int32) -> Bool {
      code == ENOENT || code == ECONNREFUSED
    }
  }

  extension UnixDatagramDatabaseIPCTransport {
    /// Returns this process's transport for `configuration`, creating it on first use.
    ///
    /// Peers discover a process rather than an individual database, and a transport already
    /// multiplexes every database identifier it is given, so databases configured alike share one
    /// endpoint. The transport is released once its last caller releases it, so hold onto the
    /// returned value for as long as its subscriptions should keep working.
    ///
    /// ```swift
    /// let transport = try UnixDatagramDatabaseIPCTransport.shared()
    /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
    /// ```
    ///
    /// - Parameter configuration: Describes the endpoint. Callers passing equal configurations
    ///   share one transport.
    /// - Returns: This process's transport for `configuration`.
    /// - Throws: A ``DatabaseIPCSystemError`` if a new transport is needed and cannot be created.
    public static func shared(
      configuration: Configuration = .default
    ) throws -> UnixDatagramDatabaseIPCTransport {
      try sharedTransports.withLock { transports in
        if let transport = transports[configuration]?.transport { return transport }
        let transport = try UnixDatagramDatabaseIPCTransport(configuration: configuration)
        transports = transports.filter { $0.value.transport != nil }
        transports[configuration] = WeakTransport(transport: transport)
        return transport
      }
    }
  }

  private struct WeakTransport: Sendable {
    weak var transport: UnixDatagramDatabaseIPCTransport?
  }

  private let sharedTransports =
    Mutex<[UnixDatagramDatabaseIPCTransport.Configuration: WeakTransport]>([:])

  /// Describes a broadcast that reached only some currently discoverable peers.
  ///
  /// The counts need not add up: a peer discovered in the coordination directory that turns out to
  /// be dead is pruned rather than counted as a failure.
  ///
  /// ```swift
  /// do {
  ///   try await transport.send(message)
  /// } catch let error as DatabaseIPCPartialDeliveryError {
  ///   logger.warning("reached \(error.deliveredPeerCount) of \(error.discoveredPeerCount) peers")
  /// }
  /// ```
  public struct DatabaseIPCPartialDeliveryError: Error, Hashable, Sendable {
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

  /// The message handlers one transport endpoint has registered, and the coordination-directory
  /// registrations that make them discoverable to peers.
  ///
  /// Peers discover a registration key rather than a database identifier, so a key stays registered
  /// for as long as any handler under it is subscribed.
  private final class DatabaseIPCHandlers: Sendable {
    private struct State: Sendable {
      var handlers = KeyedHandlerRegistry<
        DatabaseIdentifier, @Sendable (DatabaseIPCMessage) -> Void
      >()
      var isShutdown = false
    }

    private let registry: DatabaseIPCEndpointRegistry
    private let state = Mutex(State())

    init(registry: DatabaseIPCEndpointRegistry) {
      self.registry = registry
    }

    func add(
      databaseIdentifier: DatabaseIdentifier,
      handler: @escaping @Sendable (DatabaseIPCMessage) -> Void
    ) throws -> UInt64 {
      try self.state.withLock { state in
        guard !state.isShutdown else {
          throw DatabaseIPCSystemError(operation: "transport is closed", code: EBADF)
        }
        if !state.handlers.contains(databaseIdentifier),
          !self.isRegistered(databaseIdentifier, in: state)
        {
          try self.registry.register(databaseIdentifier: databaseIdentifier)
        }
        return state.handlers.insert(handler, for: databaseIdentifier).identifier
      }
    }

    func remove(identifier: UInt64, databaseIdentifier: DatabaseIdentifier) {
      self.state.withLock { state in
        guard state.handlers.remove(identifier, for: databaseIdentifier),
          !self.isRegistered(databaseIdentifier, in: state)
        else { return }
        try? self.registry.unregister(databaseIdentifier: databaseIdentifier)
      }
    }

    func receive(_ message: DatabaseIPCMessage) {
      let callbacks = self.state.withLock { $0.handlers.handlers(for: message.databaseIdentifier) }
      for callback in callbacks {
        callback(message)
      }
    }

    func shutdown() {
      let databaseIdentifiers = self.state.withLock { state -> [DatabaseIdentifier] in
        guard !state.isShutdown else { return [] }
        state.isShutdown = true
        return state.handlers.removeAll()
      }
      var unregisteredKeys = Set<String>()
      for databaseIdentifier in databaseIdentifiers
      where unregisteredKeys.insert(self.registry.registrationKey(for: databaseIdentifier)).inserted
      {
        try? self.registry.unregister(databaseIdentifier: databaseIdentifier)
      }
    }

    /// Whether a handler other than the ones for `databaseIdentifier` keeps its registration key
    /// discoverable.
    private func isRegistered(
      _ databaseIdentifier: DatabaseIdentifier,
      in state: State
    ) -> Bool {
      let key = self.registry.registrationKey(for: databaseIdentifier)
      return state.handlers.keys.contains {
        $0 != databaseIdentifier && self.registry.registrationKey(for: $0) == key
      }
    }
  }

#endif
