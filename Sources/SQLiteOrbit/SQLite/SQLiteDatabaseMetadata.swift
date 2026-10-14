/// Immutable opening settings exposed by a native SQLite driver.
///
/// Metadata can be inspected without borrowing a connection or blocking a task. It describes
/// the supplied configuration, not role-specific setup or settings changed during an access.
/// Custom drivers may conform so wrappers such as `OrbitIPCDatabase` can forward their metadata.
public protocol SQLiteDatabaseMetadata: Sendable {
  /// The database opened by the driver.
  var path: OrbitDatabasePath { get }

  /// The configuration supplied when opening the driver.
  var configuration: SQLiteConfiguration { get }

  /// The number of connections available for reading.
  var readerCount: Int { get }
}

extension SQLiteDatabaseMetadata {
  /// A serial driver has one read connection.
  public var readerCount: Int { 1 }
}
