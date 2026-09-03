/// The settings a native SQLite driver applies to every connection it opens.
public struct SQLiteConfiguration: Sendable {
  /// The SQLite build the driver runs against.
  public var library: SQLiteLibrary

  /// The number of reader connections a pool opens, and so how many reads can run at once.
  ///
  /// Each connection runs on a dispatch queue of its own, so this bounds threads rather than any
  /// share of the cooperative pool.
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

  /// Native callbacks installed on every connection.
  var connectionSetups: [SQLiteConnectionSetup]

  public init(
    library: SQLiteLibrary,
    readerCount: Int = 5,
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
    self.connectionSetups = []
  }

  /// The busy timeout in the milliseconds SQLite expects.
  var busyTimeoutMilliseconds: Int32 {
    let components = busyTimeout.components
    let milliseconds =
      components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    return Int32(clamping: milliseconds)
  }
}

/// Typed Swift callback registration was requested for a SQLite library whose callback ABI is not
/// supplied by this package.
public struct SQLiteTypedCallbacksUnavailableError: Error, CustomStringConvertible, Sendable {
  public init() {}

  public var description: String {
    """
    Typed Swift collations and functions require SQLiteLibrary.system. Register callbacks through \
    the custom SQLite build directly instead.
    """
  }
}

final class SQLiteConnectionSetup: Sendable {
  let install: @Sendable (OpaquePointer) -> Int32

  init(install: @escaping @Sendable (OpaquePointer) -> Int32) {
    self.install = install
  }
}

#if SystemSQLite
  import StructuredQueriesSQLite

  extension SQLiteConfiguration {
    /// The default configuration, running against the SQLite this package was linked against.
    public static var `default`: Self {
      Self(library: .system)
    }

    /// Registers a collating sequence on every connection opened with this configuration.
    public mutating func register(
      collation: some StructuredQueriesSQLiteCore.DatabaseCollation & Sendable
    ) {
      connectionSetups.append(
        SQLiteConnectionSetup { sqliteCrossInstall(collation: collation, on: $0) }
      )
    }

    /// Registers a scalar function on every connection opened with this configuration.
    public mutating func register(function: some ScalarDatabaseFunction & Sendable) {
      connectionSetups.append(
        SQLiteConnectionSetup { sqliteCrossInstall(function: function, on: $0) }
      )
    }

    /// Registers an aggregate function on every connection opened with this configuration.
    public mutating func register(function: some AggregateDatabaseFunction & Sendable) {
      connectionSetups.append(
        SQLiteConnectionSetup { sqliteCrossInstall(function: function, on: $0) }
      )
    }
  }
#endif
