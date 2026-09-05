/// A message exchanged by processes coordinating access to a database.
///
/// This enumeration is nonexhaustive so future package versions can introduce additional database
/// coordination messages. Switches outside this package must include an `@unknown default` case.
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
public struct DatabaseTransactionDidCommit: Hashable, Sendable {
  public let databaseIdentifier: DatabaseIdentifier

  public init(databaseIdentifier: DatabaseIdentifier) {
    self.databaseIdentifier = databaseIdentifier
  }
}
