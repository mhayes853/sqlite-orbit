/// Immutable opening settings exposed by a native SQLite driver.
///
/// Metadata can be inspected without borrowing a connection or blocking a task. It describes
/// the supplied configuration, not role-specific setup or settings changed during an access.
/// Readers expose this snapshot through ``OrbitDatabaseReader/databaseMetadata``.
public struct SQLiteDatabaseMetadata: Sendable {
  /// The database opened by the driver.
  public let path: OrbitDatabasePath

  /// The configuration supplied when opening the driver.
  public let configuration: SQLiteConfiguration

  /// The number of connections available for reading.
  public let readerCount: Int

  /// Creates a snapshot of a driver's opening settings.
  ///
  /// A serial driver has one read connection.
  public init(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration,
    readerCount: Int = 1
  ) {
    self.path = path
    self.configuration = configuration
    self.readerCount = readerCount
  }
}
