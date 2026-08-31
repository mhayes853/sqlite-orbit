/// A database driver that lends transactions to asynchronous read and write operations.
public protocol DatabaseDriver: Sendable {
  associatedtype ReadTransaction: ~Copyable, ~Escapable, DatabaseReadTransaction
  associatedtype WriteTransaction: ~Copyable, ~Escapable, DatabaseWriteTransaction

  /// The identifier used when a ``CrossProcessDatabase`` does not receive an explicit one.
  var defaultIdentifier: DatabaseIdentifier { get }

  func read<Result: Sendable>(
    _ body: @Sendable (borrowing ReadTransaction) throws -> sending Result
  ) async throws -> sending Result

  func write<Result: Sendable>(
    _ body: @Sendable (borrowing WriteTransaction) throws -> sending Result
  ) async throws -> sending Result
}
