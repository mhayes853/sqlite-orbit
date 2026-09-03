import Synchronization

/// A database IPC transport that delivers messages in-process, for testing and mocking.
///
/// Transports constructed against the same ``Network`` are peers, the way two
/// ``UnixDatagramDatabaseIPCTransport``s pointed at the same coordination directory are peers:
/// each discovers the others' subscriptions and a broadcast reaches every peer but the sender.
/// Delivery calls a peer's handlers directly instead of going through any OS resource, so peers can
/// live in the same process and a test needs no filesystem or socket cleanup.
public final class InMemoryIPCTransport: DatabaseIPCTransport, Sendable {
  /// The medium that peer transports discover each other and exchange messages through.
  ///
  /// Construct one `Network` per simulated set of coordinating processes and hand it to every
  /// transport that should see the others' messages. Transports on different networks, or with no
  /// network in common, cannot see each other.
  public final class Network: Sendable {
    fileprivate let state = Mutex(State())
    fileprivate struct State {
      var endpoints: [DatabaseIdentifier: [ObjectIdentifier: Endpoint]] = [:]
    }

    public init() {}

    fileprivate func register(_ endpoint: Endpoint, for databaseIdentifier: DatabaseIdentifier) {
      self.state.withLock {
        $0.endpoints[databaseIdentifier, default: [:]][ObjectIdentifier(endpoint)] = endpoint
      }
    }

    fileprivate func unregister(_ endpoint: Endpoint, for databaseIdentifier: DatabaseIdentifier) {
      self.state.withLock {
        $0.endpoints[databaseIdentifier]?.removeValue(forKey: ObjectIdentifier(endpoint))
        if $0.endpoints[databaseIdentifier]?.isEmpty == true {
          $0.endpoints.removeValue(forKey: databaseIdentifier)
        }
      }
    }

    fileprivate func peers(
      for databaseIdentifier: DatabaseIdentifier,
      excluding endpoint: Endpoint
    ) -> [Endpoint] {
      self.state.withLock {
        $0.endpoints[databaseIdentifier, default: [:]].values.filter { $0 !== endpoint }
      }
    }
  }

  private let network: Network
  private let endpoint = Endpoint()

  /// Creates a transport on `network`, or on a private network of its own if none is given.
  ///
  /// A transport created without an explicit network has no peers: pass the same `Network` to every
  /// transport that should discover this one.
  public init(network: Network = Network()) {
    self.network = network
  }

  deinit {
    self.endpoint.shutdown(network: self.network)
  }

  public func subscribe(
    to databaseIdentifier: DatabaseIdentifier,
    onMessage: @escaping @Sendable (DatabaseIPCMessage) -> Void
  ) throws -> SQLiteCrossSubscription {
    let endpoint = self.endpoint
    let network = self.network
    let identifier = endpoint.add(
      databaseIdentifier: databaseIdentifier,
      handler: onMessage,
      network: network
    )
    return SQLiteCrossSubscription {
      endpoint.remove(identifier: identifier, databaseIdentifier: databaseIdentifier, network: network)
    }
  }

  public func send(_ message: DatabaseIPCMessage) async throws {
    let peers = self.network.peers(for: message.databaseIdentifier, excluding: self.endpoint)
    for peer in peers {
      peer.deliver(message)
    }
  }
}

/// One process's worth of local subscriptions, keyed the way a Unix-domain peer's would be.
private final class Endpoint: Sendable {
  private struct State {
    var nextIdentifier: UInt64 = 0
    var handlers: [DatabaseIdentifier: [UInt64: @Sendable (DatabaseIPCMessage) -> Void]] = [:]
  }

  private let state = Mutex(State())
  // Serializes handler invocation for this endpoint the way a dedicated receive queue would,
  // without holding `state`'s lock (and risking deadlock) while a handler runs.
  private let deliveryLock = Mutex(())

  func add(
    databaseIdentifier: DatabaseIdentifier,
    handler: @escaping @Sendable (DatabaseIPCMessage) -> Void,
    network: InMemoryIPCTransport.Network
  ) -> UInt64 {
    self.state.withLock { state in
      let isFirstSubscription = state.handlers[databaseIdentifier] == nil
      let identifier = state.nextIdentifier
      state.nextIdentifier &+= 1
      state.handlers[databaseIdentifier, default: [:]][identifier] = handler
      if isFirstSubscription { network.register(self, for: databaseIdentifier) }
      return identifier
    }
  }

  func remove(
    identifier: UInt64,
    databaseIdentifier: DatabaseIdentifier,
    network: InMemoryIPCTransport.Network
  ) {
    let becameEmpty = self.state.withLock { state -> Bool in
      state.handlers[databaseIdentifier]?.removeValue(forKey: identifier)
      let isEmpty = state.handlers[databaseIdentifier]?.isEmpty ?? true
      if isEmpty { state.handlers.removeValue(forKey: databaseIdentifier) }
      return isEmpty
    }
    if becameEmpty { network.unregister(self, for: databaseIdentifier) }
  }

  func deliver(_ message: DatabaseIPCMessage) {
    let callbacks = self.state.withLock { state in
      Array(state.handlers[message.databaseIdentifier, default: [:]].values)
    }
    guard !callbacks.isEmpty else { return }
    self.deliveryLock.withLock { _ in
      for callback in callbacks { callback(message) }
    }
  }

  func shutdown(network: InMemoryIPCTransport.Network) {
    let databaseIdentifiers = self.state.withLock { state in
      defer { state.handlers.removeAll() }
      return Array(state.handlers.keys)
    }
    for databaseIdentifier in databaseIdentifiers {
      network.unregister(self, for: databaseIdentifier)
    }
  }
}
