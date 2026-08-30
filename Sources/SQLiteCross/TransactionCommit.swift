/// A notification that a write transaction was committed to disk.
///
/// Only successful commits should be published. Rollbacks are local concerns and must not create
/// a `TransactionCommit`.
public struct TransactionCommit: Codable, Hashable, Sendable {
  /// The database changed by the transaction.
  public let database: DatabaseIdentifier

  /// The process that originally committed the transaction.
  public let source: ProcessIdentifier

  /// The part of the database changed by the transaction.
  public let region: DatabaseChangeRegion

  public init(
    database: DatabaseIdentifier,
    source: ProcessIdentifier,
    region: DatabaseChangeRegion = .fullDatabase
  ) {
    self.database = database
    self.source = source
    self.region = region
  }
}
