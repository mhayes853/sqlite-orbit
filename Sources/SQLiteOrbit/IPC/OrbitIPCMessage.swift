/// A message exchanged by processes coordinating access to a database.
///
/// This enumeration is nonexhaustive so future package versions can introduce additional database
/// coordination messages. Switches outside this package must include an `@unknown default` case.
///
/// ```swift
/// let subscription = try transport.subscribe(to: database.id) { message in
///   switch message {
///   case .transactionDidCommit: refresh()
///   @unknown default: break
///   }
/// }
/// ```
@nonexhaustive
public enum OrbitIPCMessage: Hashable, Sendable {
  /// A write transaction committed successfully.
  case transactionDidCommit(OrbitDatabaseTransactionDidCommit)

  /// The database to which this message applies.
  public var databaseIdentifier: OrbitDatabaseIdentifier {
    switch self {
    case .transactionDidCommit(let message):
      message.databaseIdentifier
    }
  }
}

/// Announces that a database write transaction committed successfully.
///
/// ```swift
/// try await transport.send(
///   .transactionDidCommit(
///     OrbitDatabaseTransactionDidCommit(
///       databaseIdentifier: database.id,
///       region: Reminder.databaseRegion
///     )
///   )
/// )
/// ```
public struct OrbitDatabaseTransactionDidCommit: Hashable, Sendable {
  /// The database whose transaction committed.
  public let databaseIdentifier: OrbitDatabaseIdentifier

  /// The region that the transaction may have changed.
  public let region: OrbitDatabaseRegion

  /// Creates an announcement.
  ///
  /// - Parameters:
  ///   - databaseIdentifier: The database whose transaction committed.
  ///   - region: The region that the transaction may have changed.
  public init(
    databaseIdentifier: OrbitDatabaseIdentifier,
    region: OrbitDatabaseRegion
  ) {
    self.databaseIdentifier = databaseIdentifier
    self.region = region
  }
}
