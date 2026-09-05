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
  public final class UnixDatagramDatabaseIPCTransport: DatabaseIPCTransport, Sendable {
    /// Controls how a sender responds when a peer's bounded receive queue is full.
    public enum BackPressurePolicy: Hashable, Sendable {
      /// Fails the broadcast after attempting every currently discovered peer once.
      case fail

      /// Suspends and retries backpressured peers until `duration` elapses.
      case suspend(upTo: Duration)
    }

    /// Configuration for a Unix-domain datagram transport endpoint.
    public struct Configuration: Hashable, Sendable {
      /// The coordination directory used when a caller does not supply one.
      ///
      /// Processes coordinate only when they share this directory. Sandboxed applications must
      /// supply a directory inside a container both processes can reach, such as an App Group.
      public static let defaultDirectory = FileManager.default.temporaryDirectory
        .appending(path: "sqlite-orbit", directoryHint: .isDirectory)

      /// The configuration used by a database that does not supply one.
      public static let `default` = Self(backPressure: .suspend(upTo: .milliseconds(250)))

      public var directory: URL
      public var backPressure: BackPressurePolicy
      public var maximumDatagramByteCount: Int
      public var receiveBufferByteCount: Int

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
        try Task.checkCancellation()
        // AF_UNIX datagrams have no destination-specific writable event, so retry with a bounded
        // backoff rather than spinning when a particular peer's receive queue is full.
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: retryDelay)))
        guard clock.now < deadline else { break }
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
    /// endpoint. The transport is released once its last caller releases it.
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
  public struct DatabaseIPCPartialDeliveryError: Error, Hashable, Sendable {
    public let discoveredPeerCount: Int
    public let deliveredPeerCount: Int
    public let failedPeerCount: Int

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

  private final class DatabaseIPCHandlers: Sendable {
    private struct State: Sendable {
      var nextIdentifier: UInt64 = 0
      var handlers = [DatabaseIdentifier: [UInt64: @Sendable (DatabaseIPCMessage) -> Void]]()
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
        if state.handlers[databaseIdentifier] == nil {
          let registrationKey = self.registry.registrationKey(for: databaseIdentifier)
          let isRegistrationActive = state.handlers.keys.contains {
            self.registry.registrationKey(for: $0) == registrationKey
          }
          if !isRegistrationActive {
            try self.registry.register(databaseIdentifier: databaseIdentifier)
          }
          state.handlers[databaseIdentifier] = [:]
        }
        let identifier = state.nextIdentifier
        state.nextIdentifier &+= 1
        state.handlers[databaseIdentifier]?[identifier] = handler
        return identifier
      }
    }

    func remove(identifier: UInt64, databaseIdentifier: DatabaseIdentifier) {
      self.state.withLock { state in
        state.handlers[databaseIdentifier]?.removeValue(forKey: identifier)
        guard state.handlers[databaseIdentifier]?.isEmpty == true else { return }
        state.handlers.removeValue(forKey: databaseIdentifier)
        let registrationKey = self.registry.registrationKey(for: databaseIdentifier)
        let isRegistrationActive = state.handlers.keys.contains {
          self.registry.registrationKey(for: $0) == registrationKey
        }
        if !isRegistrationActive {
          try? self.registry.unregister(databaseIdentifier: databaseIdentifier)
        }
      }
    }

    func receive(_ message: DatabaseIPCMessage) {
      let callbacks = self.state.withLock { state in
        Array(state.handlers[message.databaseIdentifier, default: [:]].values)
      }
      for callback in callbacks {
        callback(message)
      }
    }

    func shutdown() {
      let databaseIdentifiers = self.state.withLock { state in
        guard !state.isShutdown else { return [DatabaseIdentifier]() }
        state.isShutdown = true
        let identifiers = Array(state.handlers.keys)
        state.handlers.removeAll()
        return identifiers
      }
      var removedRegistrationKeys = Set<String>()
      for databaseIdentifier in databaseIdentifiers {
        let registrationKey = self.registry.registrationKey(for: databaseIdentifier)
        if removedRegistrationKeys.insert(registrationKey).inserted {
          try? self.registry.unregister(databaseIdentifier: databaseIdentifier)
        }
      }
    }
  }

#endif
