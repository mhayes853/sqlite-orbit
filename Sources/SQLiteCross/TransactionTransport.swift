/// A cancellable registration with a ``TransactionTransport``.
public protocol TransactionSubscription: Sendable {
  /// Stops delivery of future commits.
  ///
  /// Calling this method more than once must be safe.
  func cancel()
}

/// Moves committed-transaction notifications between processes.
///
/// Implementations own endpoint discovery, framing, version negotiation, stale endpoint cleanup,
/// and delivery. They should not deliver commits whose `source` is their own
/// ``processIdentifier``.
public protocol TransactionTransport: Sendable {
  /// The identity of this transport endpoint.
  var processIdentifier: ProcessIdentifier { get }

  /// Begins receiving commits for a database.
  ///
  /// The handler may be invoked on any executor. Delivery is best effort: SQLite remains the
  /// source of truth, and a received commit is only a signal to fetch fresh state.
  func subscribe(
    to database: DatabaseIdentifier,
    onCommit: @escaping @Sendable (TransactionCommit) -> Void
  ) throws -> any TransactionSubscription

  /// Publishes a successful local commit to interested peer processes.
  func publish(_ commit: TransactionCommit) throws
}
