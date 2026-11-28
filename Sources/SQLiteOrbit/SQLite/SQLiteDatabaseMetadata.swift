/// The settings a native SQLite driver was opened with.
///
/// Reading a driver's metadata needs no connection, so it never waits for an access in flight.
/// It describes what the driver was given when it opened, not the settings the driver applies on
/// top of them, such as the WAL mode ``SQLitePool`` switches its writer to, nor anything changed
/// later from inside an access.
///
/// ```swift
/// let pool = try SQLitePool(path: .file(url), configuration: configuration, readerCount: 8)
/// print(pool.metadata.readerCount)  // 8
/// ```
public struct SQLiteDatabaseMetadata: Sendable {
  /// The database the driver opened.
  public let path: OrbitDatabasePath

  /// The configuration the driver was opened with.
  public let configuration: SQLiteConfiguration

  /// The most connections the driver reads through at once.
  ///
  /// A driver with a single connection, such as ``SQLiteQueue``, reads through that one.
  public let readerCount: Int

  /// Creates a description of the settings a driver was opened with.
  ///
  /// - Parameters:
  ///   - path: The database the driver opened.
  ///   - configuration: The configuration the driver was opened with.
  ///   - readerCount: The most connections the driver reads through at once.
  public init(path: OrbitDatabasePath, configuration: SQLiteConfiguration, readerCount: Int) {
    self.path = path
    self.configuration = configuration
    self.readerCount = readerCount
  }
}

/// A database that can report the settings its native SQLite driver was opened with.
///
/// ``SQLiteQueue``, ``SQLitePool`` and `TursoPool` conform. ``OrbitIPCDatabase`` reports the
/// metadata of a writer that conforms, so a custom writer that wraps one of these drivers can
/// conform by forwarding its driver's metadata:
///
/// ```swift
/// extension LoggingDatabase: SQLiteDatabaseMetadataProviding {
///   var metadata: SQLiteDatabaseMetadata { base.metadata }
/// }
/// ```
public protocol SQLiteDatabaseMetadataProviding: Sendable {
  /// The settings the database's driver was opened with.
  ///
  /// Reading it needs no connection, so it never waits for an access in flight.
  var metadata: SQLiteDatabaseMetadata { get }
}
