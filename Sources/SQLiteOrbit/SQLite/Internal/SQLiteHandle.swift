import StructuredQueries

struct SQLiteHandle: ~Copyable {
  let pointer: OpaquePointer
  let statements: SQLiteStatementCache
  let authorizer: SQLiteAuthorizerDispatcher

  let isReadOnly: Bool

  private let libraryStorage: UnsafeMutablePointer<SQLiteLibrary>

  var library: UnsafePointer<SQLiteLibrary> {
    UnsafePointer(libraryStorage)
  }

  private init(
    pointer: OpaquePointer,
    libraryStorage: UnsafeMutablePointer<SQLiteLibrary>,
    maximumCachedStatements: Int,
    isReadOnly: Bool
  ) {
    let authorizer = SQLiteAuthorizerDispatcher()
    self.pointer = pointer
    self.isReadOnly = isReadOnly
    self.libraryStorage = libraryStorage
    self.authorizer = authorizer
    self.statements = SQLiteStatementCache(
      library: UnsafePointer(libraryStorage),
      connection: pointer,
      authorizer: authorizer,
      capacity: maximumCachedStatements
    )
  }

  static func open(
    path: OrbitDatabasePath,
    flags: SQLiteOpenFlags,
    configuration: SQLiteConfiguration
  ) throws -> SQLiteHandle {
    let libraryStorage = UnsafeMutablePointer<SQLiteLibrary>.allocate(capacity: 1)
    libraryStorage.initialize(to: configuration.library)

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
      libraryStorage.deinitialize(count: 1)
      libraryStorage.deallocate()
      throw error
    }

    let handle = SQLiteHandle(
      pointer: pointer,
      libraryStorage: libraryStorage,
      maximumCachedStatements: configuration.maximumCachedStatements,
      isReadOnly: flags.contains(.readOnly)
    )
    try handle.configure(configuration)
    try handle.authorizer.install(on: pointer, using: handle.library)
    return handle
  }

  deinit {
    // Statements are finalized before the table allocation goes away, because finalizing needs it.
    statements.finalizeAll()
    _ = libraryStorage.pointee.connections.close(pointer)
    libraryStorage.deinitialize(count: 1)
    libraryStorage.deallocate()
  }

  private borrowing func configure(_ configuration: SQLiteConfiguration) throws {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    // An encrypted database is unreadable until it is keyed, so this comes before every other
    // thing the connection does rather than merely before the first statement.
    try unlock(with: configuration.key)
    _ = libraryStorage.pointee.connections.setExtendedResultCodes(pointer, 1)
    _ = libraryStorage.pointee.connections.setBusyTimeout(
      pointer,
      configuration.busyTimeoutMilliseconds
    )
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
    for sql in configuration.setupSQL {
      try execute(sql)
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
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    let observations = OrbitDatabaseTransactionObservationContext(databaseObservers: observers)
    return try withQueryOnly { try runRead(observations: observations, body) }
  }

  borrowing func readWithoutTransaction<Result: ~Copyable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    let observations = OrbitDatabaseTransactionObservationContext(databaseObservers: observers)
    return try withQueryOnly {
      try withoutTransaction { address, state in
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

  private borrowing func withQueryOnly<Result: ~Copyable>(
    _ body: () throws -> Result
  ) throws -> Result {
    // A connection opened read-only refuses writes already. One that can write must be told not
    // to for the duration, so that a read attempting a mutation fails rather than having it
    // quietly discarded by a read transaction's rollback, or kept by a statement that commits on
    // its own.
    guard !isReadOnly else { return try body() }
    // Numeric booleans are accepted by both SQLite and Turso. Turso currently parses the `ON`
    // keyword as a different expression kind than the pragma implementation accepts.
    try execute("PRAGMA query_only = 1")
    do {
      let value = try body()
      try execute("PRAGMA query_only = 0")
      return value
    } catch {
      try? execute("PRAGMA query_only = 0")
      throw error
    }
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
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    // The lifecycle is reported through the access's context rather than straight to `observers`,
    // so that observers scoped to the access see the transaction end as well.
    let observations = OrbitDatabaseTransactionObservationContext(databaseObservers: observers)
    return try runWrite(observations: observations, body)
  }

  borrowing func writeWithoutTransaction<Result: ~Copyable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    let observations = OrbitDatabaseTransactionObservationContext(databaseObservers: observers)
    // Every statement has finished by the time the access ends, so a change still pending has
    // committed. One gets here only through a cursor over raw SQL that claimed to read but wrote.
    defer { observations.didCommitPendingChanges() }
    return try withoutTransaction { address, state in
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

  private borrowing func withoutTransaction<Result: ~Copyable>(
    _ body: (UnsafePointer<SQLiteHandle>, SQLiteConnectionState) throws -> Result
  ) throws -> Result {
    let state = SQLiteConnectionState()
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
    observations: OrbitDatabaseTransactionObservationContext,
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try execute("BEGIN IMMEDIATE TRANSACTION")
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
    var statement: OpaquePointer?
    let code = sql.withCString {
      library.pointee.statements.preparation.prepare(
        connection,
        $0,
        -1,
        0,
        &statement,
        nil
      )
    }
    guard code == SQLiteResultCode.ok.rawValue, let statement else {
      if let statement {
        _ = library.pointee.statements.execution.finalize(statement)
      }
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
    }
    defer { _ = library.pointee.statements.execution.finalize(statement) }

    for (offset, binding) in bindings.enumerated() {
      try bind(binding, to: statement, at: Int32(offset + 1), library: library)
    }
    var stepCode = library.pointee.statements.execution.step(statement)
    while stepCode == SQLiteResultCode.row.rawValue {
      stepCode = library.pointee.statements.execution.step(statement)
    }
    guard stepCode == SQLiteResultCode.done.rawValue else {
      throw SQLiteError.reported(by: library.pointee, on: connection, code: stepCode, sql: sql)
    }
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

        var stepCode = library.pointee.statements.execution.step(statement)
        while stepCode == SQLiteResultCode.row.rawValue {
          stepCode = library.pointee.statements.execution.step(statement)
        }
        guard stepCode == SQLiteResultCode.done.rawValue else {
          throw SQLiteError.reported(by: library.pointee, on: connection, code: stepCode, sql: sql)
        }
      }
    }
  }
}
