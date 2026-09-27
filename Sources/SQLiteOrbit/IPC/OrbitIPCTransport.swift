/// Moves typed database coordination messages between processes.
///
/// Transports provide bounded, at-most-once, nondurable delivery. They must not add messages to an
/// unbounded user-space queue: a peer that cannot take a message now is either reported by
/// throwing, or kept a bounded summary of what it missed, such as the union of the regions of the
/// commits it could not take, which it is sent once it can. A send may reach some peers before
/// throwing.
///
/// A subscription can name the ``OrbitDatabaseRegion`` its handler cares about. Transports should
/// filter at the sender: each peer advertises the union of its subscriptions' regions for a
/// database, and a sender skips a peer none of whose subscriptions a commit concerns, so the
/// commit never wakes that process. A peer that also filters what it receives keeps a handler
/// from hearing about commits that only another handler in its process cares about.
///
/// ``UnixDatagramIPCTransport`` is the production implementation and
/// ``InMemoryIPCTransport`` is its in-process stand-in; conform your own type to reach peers over
/// some other medium.
///
/// ```swift
/// let transport = try UnixDatagramIPCTransport.shared()
/// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
/// ```
public protocol OrbitIPCTransport: Sendable {
  /// Subscribes to messages concerning `databaseIdentifier` and `region`.
  ///
  /// The region is a lower bound: a commit that overlaps it is always delivered, and one outside
  /// it may be skipped, preferably by the sender so that it never reaches this process. A
  /// subscription for ``OrbitDatabaseRegion/fullDatabase`` receives every message. When
  /// ``OrbitRegionSubscription/updateRegion(_:)`` returns, every send that starts afterwards, in
  /// any process, honors the new region, so a widened region takes effect synchronously.
  ///
  /// Handlers are invoked serially and should return promptly. Cancellation prevents new delivery,
  /// although an invocation already copied for delivery may race with cancellation.
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
  /// - Throws: An error if the transport cannot register the subscription.
  func subscribe(
    to databaseIdentifier: OrbitDatabaseIdentifier,
    region: OrbitDatabaseRegion,
    onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
  ) throws -> OrbitRegionSubscription

  /// Sends `message` to every currently discoverable subscribed peer process.
  ///
  /// Returning successfully means each discovered peer either accepted the message into its
  /// transport receive queue or, having no room, will be sent a message covering it once it does.
  /// It does not mean peer handlers processed the message.
  ///
  /// - Parameter message: The message to broadcast.
  /// - Throws: An error describing a broadcast that did not reach every discovered peer.
  func send(_ message: OrbitIPCMessage) async throws
}

extension OrbitIPCTransport {
  /// Subscribes to every message concerning `databaseIdentifier`.
  ///
  /// This subscribes for ``OrbitDatabaseRegion/fullDatabase``, whose commits are every commit.
  ///
  /// ```swift
  /// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
  /// ```
  ///
  /// - Parameters:
  ///   - databaseIdentifier: The database whose messages to receive.
  ///   - onMessage: Receives each message concerning that database.
  /// - Returns: A subscription that stops delivery when cancelled or released, and through which
  ///   its region can change.
  /// - Throws: An error if the transport cannot register the subscription.
  public func subscribe(
    to databaseIdentifier: OrbitDatabaseIdentifier,
    onMessage: @escaping @Sendable (OrbitIPCMessage) -> Void
  ) throws -> OrbitRegionSubscription {
    try self.subscribe(to: databaseIdentifier, region: .fullDatabase, onMessage: onMessage)
  }
}

extension OrbitIPCMessage {
  /// Whether a subscription for `region` must receive this message.
  func concerns(_ region: OrbitDatabaseRegion) -> Bool {
    switch self {
    case .transactionDidCommit(let commit):
      region.admits(commit.region)
    }
  }
}
