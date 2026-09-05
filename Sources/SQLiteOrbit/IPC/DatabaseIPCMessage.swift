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
public enum DatabaseIPCMessage: Hashable, Sendable {
  /// A write transaction committed successfully.
  case transactionDidCommit(DatabaseTransactionDidCommit)

  /// The database to which this message applies.
  public var databaseIdentifier: DatabaseIdentifier {
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
///   .transactionDidCommit(DatabaseTransactionDidCommit(databaseIdentifier: database.id))
/// )
/// ```
public struct DatabaseTransactionDidCommit: Hashable, Sendable {
  /// The database whose transaction committed.
  public let databaseIdentifier: DatabaseIdentifier

  /// Creates an announcement.
  ///
  /// - Parameter databaseIdentifier: The database whose transaction committed.
  public init(databaseIdentifier: DatabaseIdentifier) {
    self.databaseIdentifier = databaseIdentifier
  }
}
