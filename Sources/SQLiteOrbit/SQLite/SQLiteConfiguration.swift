import StructuredQueriesSQLite

/// The settings a native SQLite driver applies to every connection it opens.
///
/// A configuration is applied once per connection, before any transaction can reach it, so a
/// collation or function registered here is present on every connection a pool opens.
///
/// ```swift
/// var configuration = SQLiteConfiguration.default
/// configuration.readerCount = 8
/// configuration.setupSQL.append("PRAGMA synchronous = NORMAL")
/// configuration.register(function: $repeated)
/// let driver = try SQLitePool(path: .file(url), configuration: configuration)
/// ```
public struct SQLiteConfiguration: Sendable {
  /// The SQLite build the driver runs against.
  public var library: SQLiteLibrary

  /// The key a database encrypted by a build with a codec is unlocked with.
  ///
  /// Applied before anything else a connection does, so no statement and no read of the file can
  /// precede it. Setting it for a ``SQLiteLibrary`` without ``SQLiteLibrary/encryption`` fails the
  /// open with ``SQLiteEncryptionUnavailableError``.
  public var key: SQLiteKey?

  /// The number of reader connections a pool opens, and so how many reads can run at once.
  ///
  /// Each connection runs on a dispatch queue of its own, so this bounds threads rather than any
  /// share of the cooperative pool.
  public var readerCount: Int

  /// How long SQLite waits for a lock another connection or process holds before reporting
  /// `SQLITE_BUSY`.
  ///
  /// A database shared between processes needs this: without it an overlapping write fails
  /// outright rather than queueing. An access may change it for its own duration through
  /// ``SQLiteWriteConnection/busyTimeout`` or ``SQLiteReadConnection/busyTimeout``.
  public var busyTimeout: SQLiteBusyTimeout

  /// Whether foreign key enforcement is turned on.
  ///
  /// An access may change it for its own duration through
  /// ``SQLiteWriteConnection/isForeignKeysEnabled``.
  public var isForeignKeysEnabled: Bool

  /// Whether SQLite trusts schema-defined functions and virtual tables.
  public var isTrustedSchemaEnabled: Bool

  /// How many prepared statements a connection keeps for reuse.
  public var maximumCachedStatements: Int

  /// SQL run on every connection once it has been configured.
  public var setupSQL: [String]

  /// Native callbacks installed on every connection.
  public var connectionSetups: [SQLiteConnectionSetup]

  /// Creates a configuration for connections opened against `library`.
  ///
  /// - Parameters:
  ///   - library: The SQLite build the driver runs against.
  ///   - readerCount: How many reader connections a pool opens.
  ///   - busyTimeout: How long SQLite waits for a lock before reporting `SQLITE_BUSY`.
  ///   - isForeignKeysEnabled: Whether foreign key enforcement is turned on.
  ///   - isTrustedSchemaEnabled: Whether SQLite trusts schema-defined functions and virtual tables.
  ///   - maximumCachedStatements: How many prepared statements a connection keeps for reuse.
  ///   - setupSQL: SQL run on every connection once it has been configured.
  ///   - connectionSetups: Native callbacks installed on every connection.
  ///   - key: The key an encrypted database is unlocked with.
  public init(
    library: SQLiteLibrary,
    readerCount: Int = 5,
    busyTimeout: SQLiteBusyTimeout = .limit(.seconds(5)),
    isForeignKeysEnabled: Bool = true,
    isTrustedSchemaEnabled: Bool = false,
    maximumCachedStatements: Int = 64,
    setupSQL: [String] = [],
    connectionSetups: [SQLiteConnectionSetup] = [],
    key: SQLiteKey? = nil
  ) {
    self.library = library
    self.key = key
    self.readerCount = readerCount
    self.busyTimeout = busyTimeout
    self.isForeignKeysEnabled = isForeignKeysEnabled
    self.isTrustedSchemaEnabled = isTrustedSchemaEnabled
    self.maximumCachedStatements = maximumCachedStatements
    self.setupSQL = setupSQL
    self.connectionSetups = connectionSetups
  }
}

/// A native callback installed on every connection a configuration opens.
///
/// This is the escape hatch for registering what the package does not model — an update hook or a
/// virtual table module. The closure receives primitive ``SQLiteConnectionAccess`` once the
/// connection has been configured. It exposes the raw connection and its library, and can execute
/// a `QueryFragment` with bindings.
///
/// A setup runs on the connection's own queue, before any transaction can reach it.
///
/// - Important: SQLiteOrbit owns SQLite's single authorizer callback. A setup must not replace it.
///
/// ```swift
/// var configuration = SQLiteConfiguration.default
/// configuration.connectionSetups.append(
///   SQLiteConnectionSetup { connection in
///     connection.sqlite.connections.setExtendedResultCodes(connection.sqliteConnection, 1)
///   }
/// )
/// ```
public struct SQLiteConnectionSetup: Sendable {
  private let install: @Sendable (borrowing SQLiteConnectionAccess) throws -> Int32

  /// Creates a setup from a closure run on every connection.
  ///
  /// - Parameter install: Receives primitive access to the connection and returns a SQLite result
  ///   code. Anything other than `SQLITE_OK` fails the open.
  public init(
    install: @escaping @Sendable (borrowing SQLiteConnectionAccess) throws -> Int32
  ) {
    self.install = install
  }

  /// Installs the setup on `connection`.
  /// - Throws: Whatever the setup threw, or a ``SQLiteError`` when it reported a result code other
  ///   than `SQLITE_OK`. Either fails the open that ran it.
  public func callAsFunction(_ connection: borrowing SQLiteConnectionAccess) throws {
    let code = try install(connection)
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(
        by: connection.sqlite,
        on: connection.sqliteConnection,
        code: code,
        sql: nil
      )
    }
  }
}

extension SQLiteConfiguration {
  /// Registers a collating sequence on every connection opened with this configuration.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.register(collation: CaseInsensitiveCollation())
  /// ```
  ///
  /// - Parameter collation: The collation to install. Its name is what SQL refers to it by.
  public mutating func register(
    collation: some StructuredQueriesSQLiteCore.DatabaseCollation & Sendable
  ) {
    connectionSetups.append(
      SQLiteConnectionSetup(
        install: { connection in
          guard connection.sqlite.collations != nil else {
            throw SQLiteFeatureUnavailableError(
              libraryName: connection.sqlite.name,
              feature: .collations
            )
          }
          return orbitInstall(
            collation: collation,
            on: connection.sqliteConnection,
            library: connection.sqlite
          )
        }
      )
    )
  }

  /// Registers a scalar function on every connection opened with this configuration.
  ///
  /// ```swift
  /// @DatabaseFunction(isDeterministic: true)
  /// func repeated(_ text: String, _ count: Int) -> String {
  ///   String(repeating: text, count: count)
  /// }
  ///
  /// var configuration = SQLiteConfiguration.default
  /// configuration.register(function: $repeated)
  /// ```
  ///
  /// - Parameter function: The function to install. Its name is what SQL calls it by.
  public mutating func register(function: some ScalarDatabaseFunction & Sendable) {
    connectionSetups.append(
      SQLiteConnectionSetup(
        install: { connection in
          guard connection.sqlite.scalarFunctions != nil else {
            throw SQLiteFeatureUnavailableError(
              libraryName: connection.sqlite.name,
              feature: .scalarFunctions
            )
          }
          return orbitInstall(
            function: function,
            on: connection.sqliteConnection,
            library: connection.sqlite
          )
        }
      )
    )
  }

  /// Registers an aggregate function on every connection opened with this configuration.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.register(function: $longestTitle)
  /// ```
  ///
  /// - Parameter function: The function to install. Its name is what SQL calls it by.
  public mutating func register(function: some AggregateDatabaseFunction & Sendable) {
    connectionSetups.append(
      SQLiteConnectionSetup(
        install: { connection in
          guard connection.sqlite.aggregateFunctions != nil else {
            throw SQLiteFeatureUnavailableError(
              libraryName: connection.sqlite.name,
              feature: .aggregateFunctions
            )
          }
          return orbitInstall(
            function: function,
            on: connection.sqliteConnection,
            library: connection.sqlite
          )
        }
      )
    )
  }
}

#if BuiltInSQLite
  extension SQLiteConfiguration {
    /// The default configuration, running against the SQLite this package was linked against.
    ///
    /// ```swift
    /// var configuration = SQLiteConfiguration.default
    /// configuration.isForeignKeysEnabled = false
    /// ```
    public static var `default`: Self {
      #if Turso
        .turso
      #else
        Self(library: .builtIn)
      #endif
    }
  }
#endif

#if Turso
  extension SQLiteConfiguration {
    /// A configuration for the local Rust Turso database engine.
    ///
    /// Turso does not currently implement `PRAGMA trusted_schema`. Its compatibility layer also
    /// cannot install Swift functions, aggregates, or collations, so trusted schema is enabled to
    /// describe the behavior Turso actually provides rather than claiming the default protection.
    public static var turso: Self {
      Self(library: .turso, isTrustedSchemaEnabled: true)
    }
  }
#endif

#if SQLCipher
  extension SQLiteConfiguration {
    /// A configuration that opens a database encrypted under `key`.
    ///
    /// ``SQLiteLibrary/sqlCipher`` carries a codec, so the key cannot be refused the way one set
    /// against a build without one would be.
    ///
    /// ```swift
    /// let database = try OrbitDatabase(
    ///   path: .file(url),
    ///   configuration: .sqlCipher(key: .passphrase(secret))
    /// )
    /// ```
    ///
    /// - Parameter key: The key the database is unlocked with.
    /// - Returns: A configuration running against ``SQLiteLibrary/sqlCipher``.
    public static func sqlCipher(key: SQLiteKey) -> Self {
      Self(library: .sqlCipher, key: key)
    }
  }
#endif
