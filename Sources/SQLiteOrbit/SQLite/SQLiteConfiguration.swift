#if StructuredQueries
  public import StructuredQueriesSQLite
#endif

/// The settings a native SQLite driver applies to every connection it opens.
///
/// A configuration is applied once per connection, before any transaction can reach it, so a
/// collation or function registered here is present on every connection a pool opens.
///
/// ```swift
/// var configuration = SQLiteConfiguration.default
/// configuration.setups.append(.sql("PRAGMA synchronous = NORMAL"))
/// configuration.registerFunction("reversed", argumentCount: 1, flags: [.deterministic]) {
///   arguments in
///   arguments[0].textValue.map { .text(String($0.reversed())) } ?? nil
/// }
/// let driver = try SQLitePool(path: .file(url), configuration: configuration, readerCount: 8)
/// ```
public struct SQLiteConfiguration: Sendable {
  /// The SQLite build the driver runs against.
  public var library: SQLiteLibrary

  /// The key a database encrypted by a build with a codec is unlocked with.
  ///
  /// Applied before anything else a connection does, so no statement and no read of the file can
  /// precede it. Setting it for a ``SQLiteLibrary`` without ``SQLiteLibrary/encryption`` fails the
  /// open with a ``SQLiteFeatureUnavailableError`` for ``SQLiteLibraryFeature/encryption``.
  public var key: SQLiteKey?

  /// How a connection waits for a lock another connection or process holds before reporting
  /// `SQLITE_BUSY`.
  ///
  /// A database shared between processes needs this: without a wait an overlapping write fails
  /// outright rather than queueing. Defaults to ``SQLiteBusyPolicy/timeout(_:)`` of five seconds.
  /// An access may change it for its own duration through
  /// ``SQLiteWriteConnection/setBusyPolicy(_:)`` or
  /// ``SQLiteWriteConnection/withBusyPolicy(_:perform:)``, and the configured policy is put back
  /// when the access ends.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.busyPolicy = .timeout(.seconds(10))
  /// ```
  ///
  /// An ``OrbitIPCDatabase`` opened by path waits by it too, before opening any connection, for
  /// another process that is opening the same database, and fails with `SQLITE_BUSY` if that
  /// process is still at it when the policy gives up, as one that is stopped or suspended would
  /// be. A ``SQLiteBusyPolicy/handler(_:)`` is asked on each try of that wait, with `attempt`
  /// counting the tries of that one wait.
  ///
  /// A ``SQLiteBusyPolicy/handler(_:)`` for a ``SQLiteLibrary`` without
  /// ``SQLiteLibrary/busyHandler`` fails the open with ``SQLiteFeatureUnavailableError``.
  public var busyPolicy: SQLiteBusyPolicy

  /// The journal mode every writable connection switches the database to as it opens, or `nil`
  /// to leave the database in whatever mode it is in.
  ///
  /// The mode is set with the driver's own privilege, so ``authorization`` does not apply to it,
  /// and before ``setups`` run, so they run against it. A connection opened read-only, such as a
  /// pool's reader, cannot change the mode and does not try.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.journalMode = .wal
  /// ```
  ///
  /// SQLite does not report a mode it cannot switch to as an error. An in-memory database, for
  /// one, stays in ``SQLiteJournalMode/memory`` whatever is asked for. ``SQLitePool`` and
  /// ``TursoPool`` set this on their writers themselves.
  public var journalMode: SQLiteJournalMode?

  /// The authorization policy installed on every connection this configuration opens.
  ///
  /// Scoped policies add restrictions; an allowance never overrides another policy's denial.
  /// The handler runs synchronously on each connection's executor and must not access that
  /// connection. Captured policy decisions must remain stable: SQLite authorizes preparation,
  /// not every execution of a cached statement. Replace a policy through `setAuthorization(_:)`
  /// to invalidate prepared statements. A library without authorizer support fails to open.
  ///
  /// Applied after standard connection settings and ``journalMode``, and before ``setups``.
  /// Ignoring required transaction control or driver settings is treated as denial. Library
  /// recovery (rollback and restoring temporary settings) bypasses application policies.
  public var authorization: SQLiteAuthorizationHandler?

  /// Whether foreign key enforcement is turned on.
  ///
  /// An access may change it for its own duration through
  /// ``SQLiteWriteConnection/setForeignKeysEnabled(_:)``.
  public var isForeignKeysEnabled: Bool

  /// Whether SQLite trusts schema-defined functions and virtual tables.
  public var isTrustedSchemaEnabled: Bool

  /// How many prepared statements a connection keeps for reuse.
  ///
  /// The default is 64. A connection that has run more distinct SQL than this finalizes the
  /// statement it used least recently to make room, and `0` turns the cache off, so every
  /// statement is prepared anew.
  public var maximumCachedStatements: Int

  /// Setups run in order on every connection after its standard settings, ``journalMode``, and
  /// authorization policy.
  /// A thrown error stops setup and closes the connection.
  public var setups: [SQLiteSetup]

  /// Creates a configuration for connections opened against `library`.
  ///
  /// - Parameters:
  ///   - library: The SQLite build the driver runs against.
  ///   - busyPolicy: How a connection waits for a lock before reporting `SQLITE_BUSY`.
  ///   - journalMode: The journal mode writable connections switch the database to, or `nil` to
  ///     leave it alone.
  ///   - isForeignKeysEnabled: Whether foreign key enforcement is turned on.
  ///   - isTrustedSchemaEnabled: Whether SQLite trusts schema-defined functions and virtual tables.
  ///   - maximumCachedStatements: How many prepared statements a connection keeps for reuse, the
  ///     least recently used making way for new ones.
  ///   - setups: SQL and callbacks run in order on every configured connection.
  ///   - key: The key an encrypted database is unlocked with.
  ///   - authorization: The policy installed on each connection, or `nil` for no application
  ///     policy.
  public init(
    library: SQLiteLibrary,
    busyPolicy: SQLiteBusyPolicy = .timeout(.seconds(5)),
    journalMode: SQLiteJournalMode? = nil,
    isForeignKeysEnabled: Bool = true,
    isTrustedSchemaEnabled: Bool = false,
    maximumCachedStatements: Int = 64,
    setups: [SQLiteSetup] = [],
    key: SQLiteKey? = nil,
    authorization: SQLiteAuthorizationHandler? = nil
  ) {
    self.library = library
    self.key = key
    self.busyPolicy = busyPolicy
    self.journalMode = journalMode
    self.authorization = authorization
    self.isForeignKeysEnabled = isForeignKeysEnabled
    self.isTrustedSchemaEnabled = isTrustedSchemaEnabled
    self.maximumCachedStatements = maximumCachedStatements
    self.setups = setups
  }
}

extension SQLiteConfiguration {
  mutating func register(
    _ install: @escaping @Sendable (borrowing SQLiteConnectionAccess) throws -> Void
  ) {
    setups.append(SQLiteSetup(install))
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
    /// let database = try OrbitIPCDatabase(
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

// MARK: - Structured Queries

#if StructuredQueries
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
      register { try $0.register(collation: collation) }
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
      register { try $0.register(function: function) }
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
      register { try $0.register(function: function) }
    }
  }

  extension SQLiteConnectionAccess {
    /// Installs a Structured Queries collation on this connection.
    public borrowing func register(
      collation: some StructuredQueriesSQLiteCore.DatabaseCollation & Sendable
    ) throws {
      try registerCollation(collation.name) { lhs, rhs in
        switch collation.compare(lhs, rhs) {
        case .ascending: .ascending
        case .same: .same
        case .descending: .descending
        }
      }
    }

    /// Installs a Structured Queries scalar function on this connection.
    public borrowing func register(function: some ScalarDatabaseFunction & Sendable) throws {
      try registerFunction(
        function.name,
        argumentCount: function.argumentCount,
        flags: function.isDeterministic ? [.deterministic] : []
      ) { arguments in
        var decoder = SQLiteFunctionDecoder(arguments)
        return try OrbitDatabaseValue(lowering: function.invoke(&decoder))
      }
    }

    /// Installs a Structured Queries aggregate function on this connection.
    public borrowing func register(function: some AggregateDatabaseFunction & Sendable) throws {
      try registerAggregateFunction(
        function.name,
        argumentCount: function.argumentCount,
        flags: function.isDeterministic ? [.deterministic] : [],
        StructuredQueriesAggregateAccumulator(function: function)
      )
    }
  }

  // Collects each row's decoded element and hands them all to the function at the end, which is the
  // shape Structured Queries gives an aggregate.
  private struct StructuredQueriesAggregateAccumulator<Function: AggregateDatabaseFunction>:
    SQLiteAggregateAccumulator
  {
    let function: Function
    var rows: [Function.Element] = []

    mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
      var decoder = SQLiteFunctionDecoder(arguments)
      rows.append(try function.step(&decoder))
    }

    func finish() throws -> OrbitDatabaseValue {
      try OrbitDatabaseValue(lowering: function.invoke(rows))
    }
  }
#endif
