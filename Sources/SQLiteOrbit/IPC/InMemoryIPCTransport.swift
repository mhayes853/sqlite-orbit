/// A database IPC transport that delivers messages in-process, for testing and mocking.
///
/// Transports constructed against the same ``Network`` are peers, the way two
/// ``UnixDatagramIPCTransport``s pointed at the same coordination directory are peers:
/// each discovers the others' subscriptions and a broadcast reaches every peer but the sender.
/// Delivery calls a peer's handlers directly instead of going through any OS resource, so peers can
/// live in the same process and a test needs no filesystem or socket cleanup.
///
/// ```swift
/// let network = InMemoryIPCTransport.Network()
/// let database = OrbitDatabase(
///   writer: try SQLiteQueue(path: .memory),
///   id: OrbitDatabaseIdentifier(rawValue: "reminders"),
///   transport: InMemoryIPCTransport(network: network)
/// )
/// let peer = InMemoryIPCTransport(network: network)
/// let subscription = try peer.subscribe(to: database.id) { _ in refresh() }
/// ```
public final class InMemoryIPCTransport: OrbitIPCTransport, Sendable {
  /// The medium that peer transports discover each other and exchange messages through.
  ///
  /// Construct one `Network` per simulated set of coordinating processes and hand it to every
  /// transport that should see the others' messages. Transports on different networks, or with no
  /// network in common, cannot see each other.
  ///
  /// ```swift
  /// let network = InMemoryIPCTransport.Network()
  /// let sender = InMemoryIPCTransport(network: network)
  /// let receiver = InMemoryIPCTransport(network: network)
  /// ```
  public final class Network: Sendable {
    fileprivate let state = Lock(State())
    fileprivate struct State {
      var endpoints: [OrbitDatabaseIdentifier: [ObjectIdentifier: Endpoint]] = [:]
    }

    /// Creates an empty network.
    public init() {}

    fileprivate func register(_ endpoint: Endpoint, for databaseIdentifier: OrbitDatabaseIdentifier)
    {
      self.state.withLock {
        $0.endpoints[databaseIdentifier, default: [:]][ObjectIdentifier(endpoint)] = endpoint
      }
    }

    fileprivate func unregister(
      _ endpoint: Endpoint,
      for databaseIdentifier: OrbitDatabaseIdentifier
    ) {
      self.state.withLock {
        $0.endpoints[databaseIdentifier]?.removeValue(forKey: ObjectIdentifier(endpoint))
        if $0.endpoints[databaseIdentifier]?.isEmpty == true {
          $0.endpoints.removeValue(forKey: databaseIdentifier)
        }
      }
    }

    fileprivate func peers(
      for databaseIdentifier: OrbitDatabaseIdentifier,
      excluding endpoint: Endpoint
    ) -> [Endpoint] {
      self.state.withLock {
        ($0.endpoints[databaseIdentifier]?.values).map { $0.filter { $0 !== endpoint } } ?? []
      }
    }
  }

  private let network: Network
  private let endpoint = Endpoint()

  /// Creates a transport on `network`, or on a private network of its own if none is given.
  ///
  /// A transport created without an explicit network has no peers: pass the same `Network` to every
  /// transport that should discover this one.
  ///
  /// - Parameter network: The medium this transport discovers peers through.
  public init(network: Network = Network()) {
    self.network = network
  }

  deinit {
    self.endpoint.shutdown(network: self.network)
  }

  /// Subscribes to messages concerning `databaseIdentifier`.
  ///
  /// The first subscription for a database makes this transport discoverable to its peers for that
  /// database, and cancelling the last one makes it undiscoverable again.
  ///
  /// ```swift
  /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
  /// ```
  ///
  /// - Parameters:
  ///   - databaseIdentifier: The database whose messages to receive.
  ///   - onMessage: Receives each message concerning that database.
  /// - Returns: A subscription that stops delivery when cancelled or released.
  public func subscribe(
    to databaseIdentifier: OrbitDatabaseIdentifier,
    onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
  ) throws -> OrbitSubscription {
    let endpoint = self.endpoint
    let network = self.network
    let identifier = endpoint.add(
      databaseIdentifier: databaseIdentifier,
      handler: onMessage,
      network: network
    )
    return OrbitSubscription {
      endpoint.remove(
        identifier: identifier,
        databaseIdentifier: databaseIdentifier,
        network: network
      )
    }
  }

  /// Delivers `message` to every peer on this transport's network, but not to itself.
  ///
  /// Handlers run before this method returns, so a test can assert on what a peer received without
  /// waiting.
  ///
  /// ```swift
  /// try await transport.send(
  ///   .transactionDidCommit(.init(databaseIdentifier: database.id, region: .fullDatabase))
  /// )
  /// ```
  ///
  /// - Parameter message: The message to broadcast.
  public func send(_ message: OrbitIPCMessage) async throws {
    let peers = self.network.peers(for: message.databaseIdentifier, excluding: self.endpoint)
    for peer in peers {
      peer.deliver(message)
    }
  }
}

private final class Endpoint: Sendable {
  private let handlers = Lock(
    KeyedHandlerRegistry<OrbitDatabaseIdentifier, @Sendable (OrbitIPCMessage) -> Void>()
  )
  // Serializes handler invocation for this endpoint the way a dedicated receive queue would,
  // without holding the handler lock (and risking deadlock) while a handler runs.
  private let deliveryLock = Lock(())

  func add(
    databaseIdentifier: OrbitDatabaseIdentifier,
    handler: @escaping @Sendable (OrbitIPCMessage) -> Void,
    network: InMemoryIPCTransport.Network
  ) -> UInt64 {
    let added = self.handlers.withLock { $0.insert(handler, for: databaseIdentifier) }
    if added.isFirstForKey { network.register(self, for: databaseIdentifier) }
    return added.identifier
  }

  func remove(
    identifier: UInt64,
    databaseIdentifier: OrbitDatabaseIdentifier,
    network: InMemoryIPCTransport.Network
  ) {
    let becameEmpty = self.handlers.withLock { $0.remove(identifier, for: databaseIdentifier) }
    if becameEmpty { network.unregister(self, for: databaseIdentifier) }
  }

  func deliver(_ message: OrbitIPCMessage) {
    let callbacks = self.handlers.withLock { $0.handlers(for: message.databaseIdentifier) }
    guard !callbacks.isEmpty else { return }
    self.deliveryLock.withLock { _ in
      for callback in callbacks { callback(message) }
    }
  }

  func shutdown(network: InMemoryIPCTransport.Network) {
    for databaseIdentifier in self.handlers.withLock({ $0.removeAll() }) {
      network.unregister(self, for: databaseIdentifier)
    }
  }
}
