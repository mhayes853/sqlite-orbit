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
  /// open with ``SQLiteEncryptionUnavailableError``.
  public var key: SQLiteKey?

  /// How long SQLite waits for a lock another connection or process holds before reporting
  /// `SQLITE_BUSY`.
  ///
  /// A database shared between processes needs this: without it an overlapping write fails
  /// outright rather than queueing. An access may change it for its own duration through
  /// ``SQLiteWriteConnection/setBusyTimeout(_:)`` or ``SQLiteReadConnection/setBusyTimeout(_:)``.
  ///
  /// A ``busyHandler`` takes precedence over this. SQLite implements the timeout as a busy handler
  /// of its own and keeps only one per connection, so a configuration that sets both waits by the
  /// handler and never by the timeout.
  ///
  /// A ``SQLitePool`` waits by it too, before opening any connection, for another process that is
  /// opening the same database, and fails with `SQLITE_BUSY` if that process is still at it when
  /// the timeout runs out, as one that is stopped or suspended would be.
  public var busyTimeout: SQLiteBusyTimeout

  /// Decides, each time a lock is still held, whether to keep waiting for it.
  ///
  /// This is the general form of ``busyTimeout``: rather than a fixed deadline, the handler is
  /// asked again on every attempt and answers `true` to wait and try once more or `false` to give
  /// up, which is what surfaces `SQLITE_BUSY` to the statement. It is the hook for backing off,
  /// for giving up on a deadline of the caller's own, and for reporting contention.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.busyHandler = { attempt in
  ///   guard attempt <= 50 else { return false }
  ///   Thread.sleep(forTimeInterval: 0.01)
  ///   return true
  /// }
  /// ```
  ///
  /// The handler is invoked on the thread that is running the blocked statement, with `attempt`
  /// counting from `1` and rising for as long as that one statement keeps waiting. It must not
  /// touch the connection it was blocked on.
  ///
  /// Since SQLite keeps a single busy handler per connection and implements `busyTimeout` as one,
  /// setting this takes precedence: a connection opened with both installs the handler last, so
  /// the timeout never applies. An access that changes
  /// ``SQLiteWriteConnection/setBusyTimeout(_:)`` replaces the handler for its own duration, and the
  /// handler is reinstalled when the access ends along with the configured timeout.
  ///
  /// A ``SQLitePool`` asks it too, in place of ``busyTimeout``, while another process that is
  /// opening the same database holds up its own open, with `attempt` counting the tries of that
  /// one wait, and fails with `SQLITE_BUSY` when it answers `false`.
  ///
  /// Setting this for a ``SQLiteLibrary`` without ``SQLiteLibrary/busyHandler`` fails the open with
  /// ``SQLiteFeatureUnavailableError``.
  public var busyHandler: (@Sendable (_ attempt: Int) -> Bool)?

  /// The authorization policy installed on every connection this configuration opens.
  ///
  /// Scoped policies add restrictions; an allowance never overrides another policy's denial.
  /// The handler runs synchronously on each connection's executor and must not access that
  /// connection. Captured policy decisions must remain stable: SQLite authorizes preparation,
  /// not every execution of a cached statement. Replace a policy through `setAuthorization(_:)`
  /// to invalidate prepared statements. A library without authorizer support fails to open.
  ///
  /// Applied after standard connection settings and before ``setups``.
  /// Ignoring required transaction control or driver settings is treated as denial. Library recovery
  /// (rollback and restoring temporary settings) bypasses application policies.
  public var authorization: SQLiteAuthorizationHandler?

  /// Whether foreign key enforcement is turned on.
  ///
  /// An access may change it for its own duration through
  /// ``SQLiteWriteConnection/setForeignKeysEnabled(_:)``.
  public var isForeignKeysEnabled: Bool

  /// Whether SQLite trusts schema-defined functions and virtual tables.
  public var isTrustedSchemaEnabled: Bool

  /// How many prepared statements a connection keeps for reuse.
  public var maximumCachedStatements: Int

  /// Setups run in order on every connection after its standard settings and authorization policy.
  /// A thrown error stops setup and closes the connection.
  public var setups: [SQLiteSetup]

  /// Creates a configuration for connections opened against `library`.
  ///
  /// - Parameters:
  ///   - library: The SQLite build the driver runs against.
  ///   - busyTimeout: How long SQLite waits for a lock before reporting `SQLITE_BUSY`.
  ///   - isForeignKeysEnabled: Whether foreign key enforcement is turned on.
  ///   - isTrustedSchemaEnabled: Whether SQLite trusts schema-defined functions and virtual tables.
  ///   - maximumCachedStatements: How many prepared statements a connection keeps for reuse.
  ///   - setups: SQL and callbacks run in order on every configured connection.
  ///   - key: The key an encrypted database is unlocked with.
  ///   - busyHandler: Decides on each attempt whether to keep waiting for a lock, in place of
  ///     `busyTimeout`.
  ///   - authorization: The policy installed on each connection, or `nil` for no application policy.
  public init(
    library: SQLiteLibrary,
    busyTimeout: SQLiteBusyTimeout = .limit(.seconds(5)),
    isForeignKeysEnabled: Bool = true,
    isTrustedSchemaEnabled: Bool = false,
    maximumCachedStatements: Int = 64,
    setups: [SQLiteSetup] = [],
    key: SQLiteKey? = nil,
    busyHandler: (@Sendable (_ attempt: Int) -> Bool)? = nil,
    authorization: SQLiteAuthorizationHandler? = nil
  ) {
    self.library = library
    self.key = key
    self.busyTimeout = busyTimeout
    self.busyHandler = busyHandler
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
