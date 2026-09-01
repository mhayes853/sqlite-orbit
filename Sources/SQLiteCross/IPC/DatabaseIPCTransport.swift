/// Moves typed database coordination messages between processes.
///
/// Transports provide bounded, at-most-once, nondurable delivery. They must surface back pressure
/// by suspending ``send(_:)`` or throwing; they must not silently add messages to an unbounded
/// user-space queue. A send may reach some peers before throwing.
public protocol DatabaseIPCTransport: Sendable {
  /// Subscribes to messages concerning `databaseIdentifier`.
  ///
  /// Handlers are invoked serially and should return promptly. Cancellation prevents new delivery,
  /// although an invocation already copied for delivery may race with cancellation.
  func subscribe(
    to databaseIdentifier: DatabaseIdentifier,
    onMessage: @escaping @Sendable (DatabaseIPCMessage) -> Void
  ) throws -> SQLiteCrossSubscription

  /// Sends `message` to every currently discoverable subscribed peer process.
  ///
  /// Returning successfully means each discovered peer accepted the message into its transport
  /// receive queue. It does not mean peer handlers processed the message.
  func send(_ message: DatabaseIPCMessage) async throws
}
