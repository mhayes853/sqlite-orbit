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
  public var connectionSetups: [SQLiteConnectionSetup]

  public init(
    library: SQLiteLibrary,
    readerCount: Int = 5,
    busyTimeout: Duration = .seconds(5),
    isForeignKeysEnabled: Bool = true,
    isTrustedSchemaEnabled: Bool = false,
    maximumCachedStatements: Int = 64,
    setupSQL: [String] = [],
    connectionSetups: [SQLiteConnectionSetup] = []
  ) {
    self.library = library
    self.readerCount = readerCount
    self.busyTimeout = busyTimeout
    self.isForeignKeysEnabled = isForeignKeysEnabled
    self.isTrustedSchemaEnabled = isTrustedSchemaEnabled
    self.maximumCachedStatements = maximumCachedStatements
    self.setupSQL = setupSQL
    self.connectionSetups = connectionSetups
  }

  /// The busy timeout in the milliseconds SQLite expects.
  ///
  /// SQLite takes a signed millisecond count and treats anything at or below zero as "do not
  /// wait", so a duration outside that range saturates rather than overflowing into it.
  var busyTimeoutMilliseconds: Int32 {
    let components = busyTimeout.components
    guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
    guard components.seconds < Int64(Int32.max) / 1000 else { return .max }
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

/// A native callback installed on every connection a configuration opens.
///
/// This is the escape hatch for registering what the package does not model — an authorizer, an
/// update hook, a virtual table module. The closure is handed the `sqlite3 *` once the connection
/// has been configured, along with the ``SQLiteLibrary`` that connection was opened through, and
/// returns a SQLite result code. Being handed the library is what lets a setup call the same build
/// the connection belongs to, and lets one that cannot refuse the connection outright.
///
/// A setup runs on the connection's own queue, before any transaction can reach it.
public struct SQLiteConnectionSetup: Sendable {
  private let install: @Sendable (OpaquePointer, SQLiteLibrary) throws -> Int32

  public init(install: @escaping @Sendable (OpaquePointer, SQLiteLibrary) throws -> Int32) {
    self.install = install
  }

  /// Installs the setup on `connection`, which was opened through `library`.
  ///
  /// - Throws: Whatever the setup threw, or a ``SQLiteError`` when it reported a result code other
  ///   than `SQLITE_OK`. Either fails the open that ran it.
  public func callAsFunction(_ connection: OpaquePointer, library: SQLiteLibrary) throws {
    let code = try install(connection, library)
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(by: library, on: connection, code: code, sql: nil)
    }
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
        SQLiteConnectionSetup { connection, library in
          try Self.requireLinkedCallbackABI(of: library)
          return orbitInstall(collation: collation, on: connection)
        }
      )
    }

    /// Registers a scalar function on every connection opened with this configuration.
    public mutating func register(function: some ScalarDatabaseFunction & Sendable) {
      connectionSetups.append(
        SQLiteConnectionSetup { connection, library in
          try Self.requireLinkedCallbackABI(of: library)
          return orbitInstall(function: function, on: connection)
        }
      )
    }

    /// Registers an aggregate function on every connection opened with this configuration.
    public mutating func register(function: some AggregateDatabaseFunction & Sendable) {
      connectionSetups.append(
        SQLiteConnectionSetup { connection, library in
          try Self.requireLinkedCallbackABI(of: library)
          return orbitInstall(function: function, on: connection)
        }
      )
    }

    /// Refuses a connection whose SQLite is not the one these registrations compile against.
    ///
    /// A typed registration installs static C callbacks that reach for the linked SQLite's value,
    /// result, and context entry points directly rather than through `library`. Handing those
    /// callbacks a value belonging to another build would be reading one SQLite's memory with
    /// another's layout, so the connection is refused instead.
    private static func requireLinkedCallbackABI(of library: SQLiteLibrary) throws {
      guard library.supportsTypedCallbacks else { throw SQLiteTypedCallbacksUnavailableError() }
    }
  }
#endif
