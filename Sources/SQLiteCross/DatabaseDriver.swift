/// A database driver that lends transactions to asynchronous read and write operations.
public protocol DatabaseDriver: Sendable {
  associatedtype Transaction: ~Copyable, ~Escapable, DatabaseTransaction

  /// The identifier used when a ``CrossProcessDatabase`` does not receive an explicit one.
  var defaultIdentifier: DatabaseIdentifier { get }

  func read<Result: Sendable>(
    _ body: @Sendable (borrowing Transaction) throws -> sending Result
  ) async throws -> sending Result

  func write<Result: Sendable>(
    _ body: @Sendable (borrowing Transaction) throws -> sending Result
  ) async throws -> sending Result
}
