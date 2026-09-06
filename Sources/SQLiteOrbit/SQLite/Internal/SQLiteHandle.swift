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
      libraryStorage.pointee.open_v2($0, &pointer, flags.rawValue, nil)
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
        _ = libraryStorage.pointee.close_v2(pointer)
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
    _ = libraryStorage.pointee.close_v2(pointer)
    libraryStorage.deinitialize(count: 1)
    libraryStorage.deallocate()
  }

  private borrowing func configure(_ configuration: SQLiteConfiguration) throws {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    // An encrypted database is unreadable until it is keyed, so this comes before every other
    // thing the connection does rather than merely before the first statement.
    try unlock(with: configuration.key)
    _ = libraryStorage.pointee.extended_result_codes(pointer, 1)
    _ = libraryStorage.pointee.busy_timeout(pointer, configuration.busyTimeoutMilliseconds)
    try execute("PRAGMA foreign_keys = \(configuration.isForeignKeysEnabled ? "ON" : "OFF")")
    try execute("PRAGMA trusted_schema = \(configuration.isTrustedSchemaEnabled ? "ON" : "OFF")")
    // A setup is handed the library this connection was opened through, so whether it can run
    // against that build is its own question to answer rather than one asked on its behalf here.
    for setup in configuration.connectionSetups {
      try setup(pointer, library: libraryStorage.pointee)
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
          encryption.key_v2(pointer, name, bytes.baseAddress, Int32(bytes.count))
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
    _ body: (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    // A connection opened read-only refuses writes already. One that can write must be told not
    // to for the duration, so that a read attempting a mutation fails rather than quietly having
    // it discarded by the rollback below.
    guard !isReadOnly else { return try runRead(body) }
    try execute("PRAGMA query_only = ON")
    do {
      let value = try runRead(body)
      try execute("PRAGMA query_only = OFF")
      return value
    } catch {
      try? execute("PRAGMA query_only = OFF")
      throw error
    }
  }

  private borrowing func runRead<Result: ~Copyable>(
    _ body: (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try execute("BEGIN DEFERRED TRANSACTION")
    let value: Result
    do {
      value = try body(SQLiteReadTransaction(handle: self))
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
    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
      let value = try body(SQLiteWriteTransaction(handle: self, observers: observers))
      try observers?.willCommit(SQLiteReadTransaction(handle: self))
      try endTransaction(with: "COMMIT")
      observers?.didCommit(origin: .local)
      return value
    } catch {
      rollbackIgnoringFailure()
      observers?.didRollback()
      throw error
    }
  }

  private borrowing func endTransaction(with sql: String) throws {
    do {
      try execute(sql)
    } catch {
      if libraryStorage.pointee.get_autocommit(pointer) == 0 {
        try? execute("ROLLBACK")
      }
      throw error
    }
  }

  private borrowing func rollbackIgnoringFailure() {
    try? endTransaction(with: "ROLLBACK")
  }

  static func execute(
    _ sql: String,
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    authorizer: SQLiteAuthorizerDispatcher? = nil,
    observers: OrbitDatabaseTransactionObservers? = nil
  ) throws {
    // Each statement's length is passed explicitly rather than left to SQLite to measure again.
    try sql.withCString { start in
      let end = start + sql.utf8.count
      var next = start
      while next < end {
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let prepare = {
          library.pointee.prepare_v3(
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
        defer { _ = library.pointee.finalize(statement) }

        // A trailing comment or whitespace prepares nothing; stop rather than spin on it.
        guard let statement else { return }
        next = tail ?? end

        let preparedStatement = SQLitePreparedStatement(
          pointer: statement,
          authorizations: authorizations,
          library: library
        )
        observers?.didChange(in: preparedStatement.changedRegion)

        var stepCode = library.pointee.step(statement)
        while stepCode == SQLiteResultCode.row.rawValue {
          stepCode = library.pointee.step(statement)
        }
        guard stepCode == SQLiteResultCode.done.rawValue else {
          throw SQLiteError.reported(by: library.pointee, on: connection, code: stepCode, sql: sql)
        }
      }
    }
  }
}
