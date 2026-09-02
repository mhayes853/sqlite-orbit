import Foundation

/// The settings a native SQLite driver applies to every connection it opens.
public struct SQLiteConfiguration: Sendable {
  /// The SQLite build the driver runs against.
  public var library: SQLiteLibrary

  /// The number of reader connections a pool opens.
  ///
  /// Readers run their queries on the cooperative thread pool, so this also bounds how much of
  /// that pool a busy database can occupy.
  public var readerCount: Int

  /// How long SQLite waits for a lock another connection or process holds before reporting
  /// `SQLITE_BUSY`.
  ///
  /// A database shared between processes needs this: without it an overlapping write fails
  /// outright rather than queueing.
  public var busyTimeout: Duration

  /// Whether foreign key enforcement is turned on.
  public var isForeignKeysEnabled: Bool

  /// Whether SQLite trusts schema-defined functions and virtual tables.
  public var isTrustedSchemaEnabled: Bool

  /// How many prepared statements a connection keeps for reuse.
  public var maximumCachedStatements: Int

  /// SQL run on every connection once it has been configured.
  public var setupSQL: [String]

  public init(
    library: SQLiteLibrary,
    readerCount: Int = SQLiteConfiguration.automaticReaderCount,
    busyTimeout: Duration = .seconds(5),
    isForeignKeysEnabled: Bool = true,
    isTrustedSchemaEnabled: Bool = false,
    maximumCachedStatements: Int = 64,
    setupSQL: [String] = []
  ) {
    self.library = library
    self.readerCount = readerCount
    self.busyTimeout = busyTimeout
    self.isForeignKeysEnabled = isForeignKeysEnabled
    self.isTrustedSchemaEnabled = isTrustedSchemaEnabled
    self.maximumCachedStatements = maximumCachedStatements
    self.setupSQL = setupSQL
  }

  /// Half the machine's processors, which keeps readers from crowding out the rest of the
  /// cooperative pool.
  public static var automaticReaderCount: Int {
    max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
  }

  /// The busy timeout in the milliseconds SQLite expects.
  var busyTimeoutMilliseconds: Int32 {
    let components = busyTimeout.components
    let milliseconds =
      components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    return Int32(clamping: milliseconds)
  }
}

#if SystemSQLite
  extension SQLiteConfiguration {
    /// The default configuration, running against the SQLite this package was linked against.
    public static var `default`: Self {
      Self(library: .system)
    }
  }
#endif
