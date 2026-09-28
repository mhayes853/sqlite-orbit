/// A database IPC transport that delivers messages in-process, for testing and mocking.
///
/// Transports constructed against the same ``Network`` are peers, the way two
/// ``UnixDatagramIPCTransport``s pointed at the same coordination directory are peers:
/// each discovers the others' subscriptions and a broadcast reaches every peer but the sender.
/// Delivery calls a peer's handlers directly instead of going through any OS resource, so peers can
/// live in the same process and a test needs no filesystem or socket cleanup.
///
/// Delivery is filtered at the sender. Each peer advertises, for each database, the union of its
/// subscriptions' regions, and a commit is only delivered to the peers whose union it overlaps,
/// and within one of them only to the handlers whose own region it overlaps.
///
/// ```swift
/// let network = InMemoryIPCTransport.Network()
/// let database = OrbitIPCDatabase(
///   writer: try SQLitePool(path: .file(url)),
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
    private let endpoints = Lock([OrbitDatabaseIdentifier: [ObjectIdentifier: Advertisement]]())

    /// An endpoint discoverable for a database, and the union of its handlers' regions there.
    private struct Advertisement {
      let endpoint: Endpoint
      let region: OrbitDatabaseRegion
    }

    /// Creates an empty network.
    public init() {}

    /// Makes `endpoint` discoverable for a database with `region`, replacing the region it
    /// advertised before, or undiscoverable if `region` is `nil`.
    fileprivate func advertise(
      _ endpoint: Endpoint,
      region: OrbitDatabaseRegion?,
      for databaseIdentifier: OrbitDatabaseIdentifier
    ) {
      self.endpoints.withLock {
        $0[databaseIdentifier, default: [:]][ObjectIdentifier(endpoint)] =
          region.map { Advertisement(endpoint: endpoint, region: $0) }
        if $0[databaseIdentifier]?.isEmpty == true {
          $0[databaseIdentifier] = nil
        }
      }
    }

    fileprivate func advertisedRegion(
      of endpoint: Endpoint,
      for databaseIdentifier: OrbitDatabaseIdentifier
    ) -> OrbitDatabaseRegion? {
      self.endpoints.withLock { $0[databaseIdentifier]?[ObjectIdentifier(endpoint)]?.region }
    }

    fileprivate func peers(
      concernedWith message: OrbitIPCMessage,
      excluding endpoint: Endpoint
    ) -> [Endpoint] {
      self.endpoints.withLock {
        ($0[message.databaseIdentifier] ?? [:]).values
          .filter { $0.endpoint !== endpoint && message.concerns($0.region) }
          .map(\.endpoint)
      }
    }
  }

  private let network: Network
  private let endpoint: Endpoint

  /// Creates a transport on `network`, or on a private network of its own if none is given.
  ///
  /// A transport created without an explicit network has no peers: pass the same `Network` to every
  /// transport that should discover this one.
  ///
  /// - Parameter network: The medium this transport discovers peers through.
  public init(network: Network = Network()) {
    self.network = network
    self.endpoint = Endpoint(network: network)
  }

  deinit {
    self.endpoint.shutdown()
  }

  /// Subscribes to messages concerning `databaseIdentifier` and `region`.
  ///
  /// The first subscription for a database makes this transport discoverable to its peers for that
  /// database, and cancelling the last one makes it undiscoverable again. A peer only sends this
  /// transport a commit that overlaps one of its subscriptions' regions, and updating a region
  /// changes what peers send before ``OrbitRegionSubscription/updateRegion(_:)`` returns.
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
  public func subscribe(
    to databaseIdentifier: OrbitDatabaseIdentifier,
    region: OrbitDatabaseRegion,
    onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
  ) throws -> OrbitRegionSubscription {
    let endpoint = self.endpoint
    let identifier = endpoint.withHandlers(for: databaseIdentifier) {
      $0.insert(OrbitIPCHandler(region: region, onMessage: onMessage), for: databaseIdentifier)
        .identifier
    }
    return OrbitRegionSubscription(region: region) { region in
      endpoint.withHandlers(for: databaseIdentifier) {
        _ = $0.update(identifier, for: databaseIdentifier) { $0.region = region }
      }
    } onCancel: {
      endpoint.withHandlers(for: databaseIdentifier) {
        _ = $0.remove(identifier, for: databaseIdentifier)
      }
    }
  }

  /// The region this transport advertises to its peers for a database, or `nil` if it is not
  /// discoverable for that database.
  func advertisedRegion(for databaseIdentifier: OrbitDatabaseIdentifier) -> OrbitDatabaseRegion? {
    self.network.advertisedRegion(of: self.endpoint, for: databaseIdentifier)
  }

  /// Delivers `message` to every peer on this transport's network concerned with it, but not to
  /// itself.
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
    let peers = self.network.peers(concernedWith: message, excluding: self.endpoint)
    for peer in peers {
      peer.deliver(message)
    }
  }
}

private final class Endpoint: Sendable {
  private let network: InMemoryIPCTransport.Network
  private let handlers = Lock(KeyedHandlerRegistry<OrbitDatabaseIdentifier, OrbitIPCHandler>())
  // Serializes handler invocation for this endpoint the way a dedicated receive queue would,
  // without holding the handler lock (and risking deadlock) while a handler runs.
  private let deliveryLock = Lock(())

  init(network: InMemoryIPCTransport.Network) {
    self.network = network
  }

  /// Changes a database's handlers, then tells the network the union of their regions, or that
  /// there are none.
  ///
  /// The network is told while the handlers are still locked, so that a subscription added
  /// concurrently with the removal of the last one cannot have its registration undone by the
  /// removal that raced it, and so that concurrent region updates cannot leave a stale union.
  func withHandlers<Result>(
    for databaseIdentifier: OrbitDatabaseIdentifier,
    _ body: (inout KeyedHandlerRegistry<OrbitDatabaseIdentifier, OrbitIPCHandler>) -> Result
  ) -> Result {
    self.handlers.withLock { handlers in
      let result = body(&handlers)
      self.network.advertise(
        self,
        region: handlers.contains(databaseIdentifier)
          ? handlers.region(for: databaseIdentifier) : nil,
        for: databaseIdentifier
      )
      return result
    }
  }

  func deliver(_ message: OrbitIPCMessage) {
    let callbacks = self.handlers.withLock { $0.callbacks(for: message) }
    guard !callbacks.isEmpty else { return }
    self.deliveryLock.withLock { _ in
      for callback in callbacks { callback(message) }
    }
  }

  func shutdown() {
    self.handlers.withLock { handlers in
      for databaseIdentifier in handlers.removeAll() {
        self.network.advertise(self, region: nil, for: databaseIdentifier)
      }
    }
  }
}
