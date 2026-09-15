import StructuredQueries

enum SQLiteWriteTransactionMode: Equatable, Sendable {
  case immediate
  case concurrent

  var beginSQL: String {
    switch self {
    case .immediate: "BEGIN IMMEDIATE TRANSACTION"
    case .concurrent: "BEGIN CONCURRENT TRANSACTION"
    }
  }
}

struct SQLiteHandle: ~Copyable {
  let pointer: OpaquePointer
  let statements: SQLiteStatementCache
  let authorizer: SQLiteAuthorizerDispatcher

  // Every access borrows the handle, yet an access changes settings, so they live in storage of
  // their own that a borrowed handle can still mutate through.
  let settings: UnsafeMutablePointer<SQLiteConnectionSettings>

  let isReadOnly: Bool

  private let libraryStorage: UnsafeMutablePointer<SQLiteLibrary>

  // Kept where a transaction can point at it rather than copy it, since it holds arrays of
  // closures that every copy would retain.
  private let configurationStorage: UnsafeMutablePointer<SQLiteConfiguration>

  var library: UnsafePointer<SQLiteLibrary> {
    UnsafePointer(libraryStorage)
  }

  var configuration: UnsafePointer<SQLiteConfiguration> {
    UnsafePointer(configurationStorage)
  }

  private init(
    pointer: OpaquePointer,
    libraryStorage: UnsafeMutablePointer<SQLiteLibrary>,
    configurationStorage: UnsafeMutablePointer<SQLiteConfiguration>,
    isReadOnly: Bool
  ) {
    let authorizer = SQLiteAuthorizerDispatcher()
    let statements = SQLiteStatementCache(
      library: UnsafePointer(libraryStorage),
      connection: pointer,
      authorizer: authorizer,
      capacity: configurationStorage.pointee.maximumCachedStatements
    )
    self.pointer = pointer
    self.isReadOnly = isReadOnly
    self.libraryStorage = libraryStorage
    self.configurationStorage = configurationStorage
    self.authorizer = authorizer
    self.statements = statements
    // Freed by `deinit`, which also runs when configuring the handle this returns fails.
    let settings = UnsafeMutablePointer<SQLiteConnectionSettings>.allocate(capacity: 1)
    settings.initialize(
      to: SQLiteConnectionSettings(
        library: UnsafePointer(libraryStorage),
        connection: pointer,
        authorizer: authorizer,
        statements: statements,
        configuration: configurationStorage
      )
    )
    self.settings = settings
  }

  // `driverSetupSQL` runs after the configuration's own, and is kept out of the configuration a
  // transaction reports: it is how a driver sets up a connection for its role, such as a pool's
  // `query_only` readers, which a caller never asked for.
  static func open(
    path: OrbitDatabasePath,
    flags: SQLiteOpenFlags,
    configuration: SQLiteConfiguration,
    driverSetupSQL: [String] = []
  ) throws -> SQLiteHandle {
    let libraryStorage = UnsafeMutablePointer<SQLiteLibrary>.allocate(capacity: 1)
    libraryStorage.initialize(to: configuration.library)
    let configurationStorage = UnsafeMutablePointer<SQLiteConfiguration>.allocate(capacity: 1)
    configurationStorage.initialize(to: configuration)

    var pointer: OpaquePointer?
    let code = path.sqlitePath.withCString {
      libraryStorage.pointee.connections.open($0, &pointer, flags.rawValue, nil)
    }
    guard code == SQLiteResultCode.ok.rawValue, let pointer else {
      // SQLite hands back a connection even for most failed opens, and it is the caller's to close.
      let error = SQLiteError.reported(
        by: libraryStorage.pointee,
        on: pointer,
        code: code,
        sql: nil
      )
      if let pointer {
        _ = libraryStorage.pointee.connections.close(pointer)
      }
      configurationStorage.deinitialize(count: 1)
      configurationStorage.deallocate()
      libraryStorage.deinitialize(count: 1)
      libraryStorage.deallocate()
      throw error
    }

    let handle = SQLiteHandle(
      pointer: pointer,
      libraryStorage: libraryStorage,
      configurationStorage: configurationStorage,
      isReadOnly: flags.contains(.readOnly)
    )
    try handle.configure(configuration, driverSetupSQL: driverSetupSQL)
    try handle.authorizer.install(on: pointer, using: handle.library)
    return handle
  }

  deinit {
    // Statements are finalized before the table allocation goes away, because finalizing needs it.
    statements.finalizeAll()
    _ = libraryStorage.pointee.connections.close(pointer)
    // The settings only point at the connection and the table, and never touch either on their
    // way out, so they go once the connection has closed and before the table does.
    settings.deinitialize(count: 1)
    settings.deallocate()
    configurationStorage.deinitialize(count: 1)
    configurationStorage.deallocate()
    libraryStorage.deinitialize(count: 1)
    libraryStorage.deallocate()
  }

  private borrowing func configure(
    _ configuration: SQLiteConfiguration,
    driverSetupSQL: [String]
  ) throws {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    // An encrypted database is unreadable until it is keyed, so this comes before every other
    // thing the connection does rather than merely before the first statement.
    try unlock(with: configuration.key)
    _ = libraryStorage.pointee.connections.setExtendedResultCodes(pointer, 1)
    _ = libraryStorage.pointee.connections.setBusyTimeout(
      pointer,
      configuration.busyTimeout.milliseconds
    )
    // Last of the two, since SQLite keeps one busy handler and the timeout is one: a configuration
    // that sets both waits by the handler.
    try installBusyHandler()
    try execute("PRAGMA foreign_keys = \(configuration.isForeignKeysEnabled ? "ON" : "OFF")")
    let connection = SQLiteConnectionAccess(handle: self)
    if let trustedSchema = libraryStorage.pointee.trustedSchema {
      try trustedSchema(connection, configuration.isTrustedSchemaEnabled)
    } else if !configuration.isTrustedSchemaEnabled {
      throw SQLiteFeatureUnavailableError(
        libraryName: libraryStorage.pointee.name,
        feature: .trustedSchema
      )
    }
    // A setup is handed the library this connection was opened through, so whether it can run
    // against that build is its own question to answer rather than one asked on its behalf here.
    for setup in configuration.connectionSetups {
      try setup(connection)
    }
    for sql in configuration.setupSQL + driverSetupSQL {
      try execute(sql)
    }
  }

  private borrowing func installBusyHandler() throws {
    guard configurationStorage.pointee.busyHandler != nil else { return }
    guard libraryStorage.pointee.busyHandler != nil else {
      throw SQLiteFeatureUnavailableError(
        libraryName: libraryStorage.pointee.name,
        feature: .busyHandler
      )
    }
    let code = SQLiteBusyHandlerInstallation.install(
      on: pointer,
      library: library,
      configuration: configurationStorage
    )
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(by: libraryStorage.pointee, on: pointer, code: code, sql: nil)
    }
  }

  private borrowing func unlock(with key: SQLiteKey?) throws {
    guard let key else { return }
    guard let encryption = libraryStorage.pointee.encryption else {
      throw SQLiteEncryptionUnavailableError()
    }
    // The key is passed as bytes, so it never reaches a statement and never lands in the `sql` of
    // the error a wrong key produces.
    let code = key.withUnsafeBytes { bytes in
      "main"
        .withCString { name in
          encryption.key(pointer, name, bytes.baseAddress, Int32(bytes.count))
        }
    }
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(by: libraryStorage.pointee, on: pointer, code: code, sql: nil)
    }
    // A codec accepts any key and only reports a wrong one when something reads the file. Reading
    // the schema here is what turns that into a failed open rather than a failed first query.
    try execute("SELECT count(*) FROM sqlite_schema")
  }

  borrowing func execute(_ sql: String) throws {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    try Self.execute(sql, on: pointer, library: library)
  }

  borrowing func read<Result: ~Copyable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try withConnectionAccess(observers: observers) { observations in
      try beginQueryOnly()
      return try runRead(observations: observations, body)
    }
  }

  borrowing func readWithoutTransaction<Result: ~Copyable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try withConnectionAccess(observers: observers) { observations in
      try beginQueryOnly()
      return try withoutTransaction { address, state in
        try body(
          SQLiteReadConnection(
            handle: self,
            at: address,
            observations: observations,
            state: state
          )
        )
      }
    }
  }

  private borrowing func beginQueryOnly() throws {
    // A connection opened read-only refuses writes already. One that can write must be told not
    // to for the duration, so that a read attempting a mutation fails rather than having it
    // quietly discarded by a read transaction's rollback, or kept by a statement that commits on
    // its own. The access turns it back off with the rest of its settings.
    guard !isReadOnly else { return }
    try settings.pointee.setQueryOnly(true)
  }

  // Every access runs its body through here, so that none begins under a setting an earlier one
  // changed, and none ends without putting back what it changed.
  private borrowing func withRestoredSettings<Result: ~Copyable>(
    _ body: () throws -> Result
  ) throws -> Result {
    // Whatever an earlier access could not restore is retried first. A setting that still cannot
    // be restored fails this access, rather than letting it run under what the earlier one left.
    try settings.pointee.restore()
    let value: Result
    do {
      value = try body()
    } catch {
      // The body's failure is the one worth reporting. A setting that still cannot be restored
      // remains changed, so the next access retries it before running.
      try? settings.pointee.restore()
      throw error
    }
    try settings.pointee.restore()
    return value
  }

  // Every read transaction begins here, whether `read` opens it or a read connection's
  // `transaction` does.
  borrowing func runRead<Result: ~Copyable>(
    observations: OrbitDatabaseTransactionObservationContext,
    _ body: (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try execute("BEGIN DEFERRED TRANSACTION")
    statements.invalidateIfSchemaChanged()
    let value: Result
    do {
      value = try body(SQLiteReadTransaction(handle: self, observations: observations))
    } catch {
      // The body's failure is the one worth reporting, so a failing rollback does not mask it.
      rollbackIgnoringFailure()
      throw error
    }
    try endTransaction(with: "ROLLBACK")
    return value
  }

  borrowing func write<Result: ~Copyable>(
    mode: SQLiteWriteTransactionMode = .immediate,
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try withConnectionAccess(observers: observers) { observations in
      try runWrite(mode: mode, observations: observations, body)
    }
  }

  borrowing func writeWithoutTransaction<Result: ~Copyable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try withConnectionAccess(observers: observers, commitsPendingChanges: true) { observations in
      try withoutTransaction { address, state in
        try body(
          SQLiteWriteConnection(
            handle: self,
            at: address,
            observations: observations,
            state: state
          )
        )
      }
    }
  }

  /// Establishes the invariants shared by every transaction and connection access.
  private borrowing func withConnectionAccess<Result: ~Copyable>(
    observers: OrbitDatabaseTransactionObservers?,
    commitsPendingChanges: Bool = false,
    _ body: (OrbitDatabaseTransactionObservationContext) throws -> Result
  ) throws -> Result {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    let observations = OrbitDatabaseTransactionObservationContext(databaseObservers: observers)
    defer {
      if commitsPendingChanges {
        // Every statement has finished by now, so any remaining change has committed.
        observations.didCommitPendingChanges()
      }
    }
    return try withRestoredSettings { try body(observations) }
  }

  // The caller restores the access's settings once this returns, which is after any transaction
  // left open has been rolled back: SQLite ignores `PRAGMA foreign_keys` inside one.
  private borrowing func withoutTransaction<Result: ~Copyable>(
    _ body: (UnsafePointer<SQLiteHandle>, SQLiteConnectionState) throws -> Result
  ) throws -> Result {
    let state = SQLiteConnectionState()
    // Declared before the handler below is installed, so that it runs after the handler has been
    // taken back off: the rollback is itself transaction control, which the handler would refuse.
    defer {
      // The handler below only sees statements as they are prepared, so one the cache prepared
      // where transaction control was allowed, such as inside a `transaction`, can still open a
      // transaction when it is reused outside. A transaction left open would hold its locks, and
      // whatever it changed, into the next access.
      if libraryStorage.pointee.connections.isAutocommit(pointer) == 0 {
        rollbackIgnoringFailure()
      }
    }
    // Outside a transaction each statement commits on its own, which is what tells the
    // connection when to report a change as committed. A statement that began or ended a
    // transaction behind its back would leave it reporting commits that have not happened, so
    // only the connection's own `transaction` may run one.
    let handler: SQLiteAuthorizerDispatcher.Handler = { authorization in
      switch authorization.action {
      case .transaction, .savepoint: state.isInTransaction ? .allow : .deny
      default: .allow
      }
    }
    return try authorizer.withHandler(handler) {
      // The connection reaches back to the handle to run its transactions. The address is only
      // valid for this call, which the connection, being nonescapable, cannot outlive.
      try withUnsafePointer(to: self) { address in try body(address, state) }
    }
  }

  // Every write transaction begins here, whether `write` opens it or a write connection's
  // `transaction` does, and reports its lifecycle to the context of the access it belongs to.
  borrowing func runWrite<Result: ~Copyable>(
    mode: SQLiteWriteTransactionMode = .immediate,
    observations: OrbitDatabaseTransactionObservationContext,
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try execute(mode.beginSQL)
    statements.invalidateIfSchemaChanged()
    do {
      let value = try body(SQLiteWriteTransaction(handle: self, observations: observations))
      try observations.willCommit(SQLiteReadTransaction(handle: self, observations: observations))
      try endTransaction(with: "COMMIT")
      observations.didCommit(origin: .local)
      return value
    } catch {
      rollbackIgnoringFailure()
      observations.didRollback()
      throw error
    }
  }

  private borrowing func endTransaction(with sql: String) throws {
    do {
      try execute(sql)
    } catch {
      if libraryStorage.pointee.connections.isAutocommit(pointer) == 0 {
        try? execute("ROLLBACK")
      }
      throw error
    }
  }

  private borrowing func rollbackIgnoringFailure() {
    try? endTransaction(with: "ROLLBACK")
  }

  static func execute(
    _ query: QueryFragment,
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>
  ) throws {
    let (sql, bindings) = prepareQuery(query)
    guard let statement = try library.pointee.prepare(sql, on: connection) else {
      throw SQLiteError.reported(
        by: library.pointee,
        on: connection,
        code: SQLiteResultCode.ok.rawValue,
        sql: sql
      )
    }
    defer { _ = library.pointee.statements.execution.finalize(statement) }
    try bind(bindings, to: statement, library: library)
    try stepToCompletion(statement, on: connection, library: library, sql: sql)
  }

  static func execute(
    _ sql: String,
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    authorizer: SQLiteAuthorizerDispatcher? = nil,
    statements: SQLiteStatementCache? = nil,
    observations: OrbitDatabaseTransactionObservationContext? = nil
  ) throws {
    // Each statement's length is passed explicitly rather than left to SQLite to measure again.
    try sql.withCString { start in
      let end = start + sql.utf8.count
      var next = start
      while next < end {
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let prepare = {
          library.pointee.statements.preparation.prepare(
            connection,
            next,
            Int32(end - next),
            0,
            &statement,
            &tail
          )
        }
        let code: Int32
        let authorizations: [SQLiteAuthorization]
        if let authorizer {
          (code, authorizations) = authorizer.recordingAuthorizations(during: prepare)
        } else {
          code = prepare()
          authorizations = []
        }
        guard code == SQLiteResultCode.ok.rawValue else {
          throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
        }
        defer { _ = library.pointee.statements.execution.finalize(statement) }

        // A trailing comment or whitespace prepares nothing; stop rather than spin on it.
        guard let statement else { return }
        next = tail ?? end

        if let statements,
          sqliteInvalidatesStatementCache(
            after: authorizations,
            statement: statement,
            library: library
          )
        {
          statements.invalidate()
        }

        if let observations {
          let preparedStatement = SQLitePreparedStatement(
            pointer: statement,
            authorizations: authorizations,
            statements: statements,
            connection: connection,
            authorizer: authorizer,
            library: library
          )
          observations.didRead(in: preparedStatement.readRegion)
          observations.didChange(in: preparedStatement.changedRegion)
        }

        try stepToCompletion(statement, on: connection, library: library, sql: sql)
      }
    }
  }

  // Steps past every row the statement produces, which is how a statement run for its effect is
  // run to its end.
  private static func stepToCompletion(
    _ statement: OpaquePointer,
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    sql: String
  ) throws {
    var code: Int32
    repeat {
      code = library.pointee.statements.execution.step(statement)
    } while code == SQLiteResultCode.row.rawValue
    guard code == SQLiteResultCode.done.rawValue else {
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
    }
  }
}

extension SQLiteLibrary {
  // Compiles the first statement in `sql`, or returns `nil` when it holds none, as a comment or
  // whitespace does. SQLite can hand back a statement even when it reports a failure, so one is
  // finalized here rather than left for the caller to leak.
  func prepare(
    _ sql: String,
    on connection: OpaquePointer,
    flags: UInt32 = 0
  ) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    let code = sql.withCString {
      statements.preparation.prepare(connection, $0, -1, flags, &statement, nil)
    }
    guard code == SQLiteResultCode.ok.rawValue else {
      if let statement { _ = statements.execution.finalize(statement) }
      throw SQLiteError.reported(by: self, on: connection, code: code, sql: sql)
    }
    return statement
  }
}
