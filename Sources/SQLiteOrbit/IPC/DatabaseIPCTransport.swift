/// Moves typed database coordination messages between processes.
///
/// Transports provide bounded, at-most-once, nondurable delivery. They must surface back pressure
/// by suspending ``send(_:)`` or throwing; they must not silently add messages to an unbounded
/// user-space queue. A send may reach some peers before throwing.
///
/// ``UnixDatagramIPCTransport`` is the production implementation and
/// ``InMemoryIPCTransport`` is its in-process stand-in; conform your own type to reach peers over
/// some other medium.
///
/// ```swift
/// let transport = try UnixDatagramIPCTransport.shared()
/// let subscription = try transport.subscribe(to: database.id) { _ in refresh() }
/// ```
public protocol DatabaseIPCTransport: Sendable {
  /// Subscribes to messages concerning `databaseIdentifier`.
  ///
  /// Handlers are invoked serially and should return promptly. Cancellation prevents new delivery,
  /// although an invocation already copied for delivery may race with cancellation.
  ///
  /// - Parameters:
  ///   - databaseIdentifier: The database whose messages to receive.
  ///   - onMessage: Receives each message concerning that database.
  /// - Returns: A subscription that stops delivery when cancelled or released.
  /// - Throws: An error if the transport cannot register the subscription.
  func subscribe(
    to databaseIdentifier: DatabaseIdentifier,
    onMessage: @escaping @Sendable (DatabaseIPCMessage) -> Void
  ) throws -> OrbitSubscription

  /// Sends `message` to every currently discoverable subscribed peer process.
  ///
  /// Returning successfully means each discovered peer accepted the message into its transport
  /// receive queue. It does not mean peer handlers processed the message.
  ///
  /// - Parameter message: The message to broadcast.
  /// - Throws: An error describing a broadcast that did not reach every discovered peer.
  func send(_ message: DatabaseIPCMessage) async throws
}
