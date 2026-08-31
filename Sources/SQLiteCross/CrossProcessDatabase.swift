/// The public database handle that will coordinate local transactions with cross-process work.
///
/// This initial implementation intentionally covers local transactions only. Cross-process IPC
/// and observation will be layered on without changing the driver-facing transaction model.
public final class CrossProcessDatabase<Driver: DatabaseDriver>: Identifiable, Sendable {
  public let id: DatabaseIdentifier
  public let driver: Driver

  public init(driver: Driver, id: DatabaseIdentifier? = nil) {
    self.driver = driver
    self.id = id ?? driver.defaultIdentifier
  }

  public func read<Result: Sendable>(
    _ body: @Sendable (borrowing Driver.ReadTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await driver.read(body)
  }

  public func write<Result: Sendable>(
    _ body: @Sendable (borrowing Driver.WriteTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await driver.write(body)
  }
}
