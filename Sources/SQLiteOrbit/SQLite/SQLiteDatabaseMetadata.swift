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
