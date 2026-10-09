/// Owns a native SQLite connection and lends scoped read or write access.
///
/// The owner is noncopyable and does not cross concurrency boundaries. A driver chooses its
/// executor and transaction boundaries; each lending call is synchronous and exclusive.
/// Borrowed connections and their cursors cannot outlive the call that lent them.
public struct SQLiteConnection: ~Copyable {
  let pointer: OpaquePointer
  let statements: SQLiteStatementCache
  let authorizer: SQLiteAuthorizerDispatcher

  // Every access borrows the handle, yet an access changes settings, so they live in storage of
  // their own that a borrowed handle can still mutate through.
  let settings: UnsafeMutablePointer<SQLiteConnectionSettings>

  /// Whether the connection was opened with read-only access.
  public let isReadOnly: Bool

  private let libraryStorage: UnsafeMutablePointer<SQLiteLibrary>

  // Kept where a transaction can point at it rather than copy it, since it holds arrays of
  // closures that every copy would retain.
  private let configurationStorage: UnsafeMutablePointer<SQLiteConfiguration>

  var library: UnsafePointer<SQLiteLibrary> {
    UnsafePointer(libraryStorage)
  }

  /// The configuration used to open this connection.
  public var configuration: SQLiteConfiguration { configurationStorage.pointee }

  var configurationPointer: UnsafePointer<SQLiteConfiguration> {
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

  /// Opens and configures a connection. Closing is automatic when the owner is destroyed.
  public init(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration,
    flags: SQLiteOpenFlags = [.readWrite, .create, .noMutex]
  ) throws {
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

    let handle = SQLiteConnection(
      pointer: pointer,
      libraryStorage: libraryStorage,
      configurationStorage: configurationStorage,
      isReadOnly: flags.contains(.readOnly)
    )
    try handle.authorizer.install(on: pointer, using: handle.library)
    try handle.configure(configuration)
    self = consume handle
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
    _ configuration: SQLiteConfiguration
  ) throws {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    // An encrypted database is unreadable until it is keyed, so this comes before every other
    // thing the connection does rather than merely before the first statement.
    try unlock(with: configuration.key)
    _ = libraryStorage.pointee.connections.setExtendedResultCodes(pointer, 1)
    let timeoutCode = libraryStorage.pointee.connections.setBusyTimeout(
      pointer,
      configuration.busyTimeout.milliseconds
    )
    guard timeoutCode == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(
        by: libraryStorage.pointee,
        on: pointer,
        code: timeoutCode,
        sql: nil
      )
    }
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
    if let authorization = configuration.authorization {
      try connection.setAuthorization(authorization)
    }
    for setup in configuration.setups {
      try setup(connection)
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
    try Self.executeScript(sql, on: pointer, library: library)
  }

  /// Lends primitive access for connection-local setup, such as installing functions or collations.
  ///
  /// Registrations survive this scope. SQL executes without an explicit transaction; use
  /// `withReadConnection` or `withWriteConnection` when transaction control is needed.
  /// A read-only connection remains read-only. Raw setup changes, including PRAGMAs, can persist.
  public mutating func withConnectionAccess<Result: ~Copyable>(
    cancellation: SQLiteConnectionCancellation? = nil,
    _ body: (borrowing SQLiteConnectionAccess) throws -> Result
  ) throws -> Result {
    if isReadOnly {
      return try withReadConnection(cancellation: cancellation) { try body($0.base.access) }
    }
    return try withWriteConnection(cancellation: cancellation) { try body($0.base.base.access) }
  }

  /// Lends read access, temporarily enforcing query-only mode on writable connections.
  /// Call the borrowed connection's `transaction` method when a stable snapshot is needed.
  public mutating func withReadConnection<Result: ~Copyable>(
    cancellation: SQLiteConnectionCancellation? = nil,
    _ body: (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try withManagedAccess(cancellation: cancellation) { observations in
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
    try restoreSettings()
    let value: Result
    do {
      value = try body()
    } catch {
      // The body's failure is the one worth reporting. A setting that still cannot be restored
      // remains changed, so the next access retries it before running.
      try? restoreSettings()
      throw error
    }
    try restoreSettings()
    return value
  }

  private borrowing func restoreSettings() throws {
    try authorizer.withoutUserAuthorization { try settings.pointee.restore() }
  }

  // The borrowed read connection opens its transactions here.
  borrowing func runRead<Result: ~Copyable>(
    observations: SQLiteConnectionEvents,
    _ body: (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try authorizer.requiringExecution { try execute("BEGIN DEFERRED TRANSACTION") }
    statements.invalidateIfSchemaChanged()
    let value: Result
    do {
      value = try body(SQLiteReadTransaction(handle: self, observations: observations))
    } catch {
      // The body's failure is the one worth reporting, so a failing rollback does not mask it.
      rollbackIgnoringFailure()
      throw error
    }
    try authorizer.withoutUserAuthorization { try endTransaction(with: "ROLLBACK") }
    return value
  }

  /// Lends write access. Statements commit independently unless grouped in `transaction`.
  /// A connection opened read-only rejects this call before invoking `body`.
  public mutating func withWriteConnection<Result: ~Copyable>(
    cancellation: SQLiteConnectionCancellation? = nil,
    _ body: (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    guard !isReadOnly else {
      throw SQLiteError(
        code: .readOnly,
        message: "Cannot lend write access to a read-only connection"
      )
    }
    return try withManagedAccess(cancellation: cancellation, commitsPendingChanges: true) {
      observations in
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
  private borrowing func withManagedAccess<Result: ~Copyable>(
    cancellation: SQLiteConnectionCancellation?,
    commitsPendingChanges: Bool = false,
    _ body: (SQLiteConnectionEvents) throws -> Result
  ) throws -> Result {
    let binding = SQLiteCurrentLibrary.bind(library)
    defer { SQLiteCurrentLibrary.unbind(restoring: binding) }
    let observations = SQLiteConnectionEvents()
    defer {
      if commitsPendingChanges {
        // Every statement has finished by now, so any remaining change has committed.
        observations.didCommitPendingChanges()
      }
    }
    guard let cancellation else {
      return try withRestoredSettings { try body(observations) }
    }
    let address = UInt(bitPattern: pointer)
    let interrupt = libraryStorage.pointee.connections.interrupt
    let interruptConnection: @Sendable () -> Void = {
      interrupt(OpaquePointer(bitPattern: address))
    }
    return try cancellation.withInterruption(interrupt: interruptConnection) {
      try withRestoredSettings { try body(observations) }
    }
  }

  borrowing func withStatementExecution<Result: ~Copyable>(
    _ step: @escaping @Sendable (OpaquePointer?) -> Int32,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    let previous = libraryStorage.pointee.statements.execution.step
    libraryStorage.pointee.statements.execution.step = step
    defer { libraryStorage.pointee.statements.execution.step = previous }
    return try operation()
  }

  // The caller restores the access's settings once this returns, which is after any transaction
  // left open has been rolled back: SQLite ignores `PRAGMA foreign_keys` inside one.
  private borrowing func withoutTransaction<Result: ~Copyable>(
    _ body: (UnsafePointer<SQLiteConnection>, SQLiteConnectionState) throws -> Result
  ) throws -> Result {
    let state = SQLiteConnectionState()
    // Declared before the handler below is installed, so that it runs after the handler has been
    // taken back off: the rollback is itself transaction control, which the handler would refuse.
    defer {
      // Raw native access can still leave a transaction open. Roll it back so its locks and
      // uncommitted changes cannot survive into the next access.
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

  // The borrowed write connection opens transactions here and reports their lifecycle to the
  // access-local event router.
  borrowing func runWrite<Result: ~Copyable>(
    mode: SQLiteWriteTransactionMode = .immediate,
    observations: SQLiteConnectionEvents,
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try authorizer.requiringExecution { try execute(mode.beginSQL) }
    statements.invalidateIfSchemaChanged()
    do {
      let value = try body(SQLiteWriteTransaction(handle: self, observations: observations))
      try observations.willCommit(SQLiteReadTransaction(handle: self, observations: observations))
      try endTransaction(with: "COMMIT")
      observations.didCommit()
      return value
    } catch {
      rollbackIgnoringFailure()
      observations.didRollback()
      throw error
    }
  }

  private borrowing func endTransaction(with sql: String) throws {
    do {
      try authorizer.requiringExecution { try execute(sql) }
    } catch {
      if libraryStorage.pointee.connections.isAutocommit(pointer) == 0 {
        authorizer.withoutUserAuthorization { try? execute("ROLLBACK") }
      }
      throw error
    }
  }

  private borrowing func rollbackIgnoringFailure() {
    authorizer.withoutUserAuthorization { try? endTransaction(with: "ROLLBACK") }
  }

  static func execute(
    _ query: SQL,
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>
  ) throws {
    // SQL that holds no statement, such as an empty query, has nothing to run.
    let text = query.text
    guard let statement = try library.pointee.prepareStatement(text, on: connection) else {
      return
    }
    defer { _ = library.pointee.statements.execution.finalize(statement) }
    try bind(query, to: statement, library: library)
    try stepToCompletion(statement, on: connection, library: library, sql: text)
  }

  static func executeScript(
    _ sql: String,
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    authorizer: SQLiteAuthorizerDispatcher? = nil,
    statements: SQLiteStatementCache? = nil,
    observations: SQLiteConnectionEvents? = nil
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
        let authorizations: [SQLiteRawAuthorization]
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
        let isReadOnly = library.pointee.statements.inspection.isReadOnly(statement) != 0

        if let statements,
          sqliteInvalidatesStatementCache(after: authorizations, isReadOnly: isReadOnly)
        {
          statements.invalidate()
        }

        if let observations {
          let preparedStatement = SQLitePreparedStatement(
            pointer: statement,
            isReadOnly: isReadOnly,
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
  // Compiles the first statement in fixed SQL the package wrote itself, or returns `nil` when it
  // holds none, as a comment or whitespace does.
  func prepare(
    _ sql: String,
    on connection: OpaquePointer,
    flags: UInt32 = 0
  ) throws -> OpaquePointer? {
    try prepare(sql, on: connection, flags: flags, isSingleStatement: false)
  }

  // Compiles the one statement a caller's SQL holds, or returns `nil` when it holds none, as an
  // empty query, whitespace, or a comment does. SQL holding a second statement is refused, since
  // a cursor steps only the first and the rest would otherwise be silently skipped.
  func prepareStatement(
    _ sql: String,
    on connection: OpaquePointer,
    flags: UInt32 = 0
  ) throws -> OpaquePointer? {
    try prepare(sql, on: connection, flags: flags, isSingleStatement: true)
  }

  // SQLite can hand back a statement even when it reports a failure, so one is finalized here
  // rather than left for the caller to leak.
  private func prepare(
    _ sql: String,
    on connection: OpaquePointer,
    flags: UInt32,
    isSingleStatement: Bool
  ) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    var hasTrailingStatement = false
    let code = sql.withCString { start in
      var tail: UnsafePointer<CChar>?
      let code = statements.preparation.prepare(connection, start, -1, flags, &statement, &tail)
      if isSingleStatement, code == SQLiteResultCode.ok.rawValue, let tail {
        hasTrailingStatement = self.hasStatement(in: tail, on: connection)
      }
      return code
    }
    guard code == SQLiteResultCode.ok.rawValue else {
      if let statement { _ = statements.execution.finalize(statement) }
      throw SQLiteError.reported(by: self, on: connection, code: code, sql: sql)
    }
    guard !hasTrailingStatement else {
      if let statement { _ = statements.execution.finalize(statement) }
      throw SQLiteError(
        code: .error,
        message: "SQL holds more than one statement; run a script with executeScript(_:)",
        sql: sql
      )
    }
    return statement
  }

  // Whether the text after a statement holds another one rather than only whitespace, semicolons,
  // and comments. The common case, nothing at all, is answered without compiling anything.
  private func hasStatement(in text: UnsafePointer<CChar>, on connection: OpaquePointer) -> Bool {
    var next = text
    while next.pointee != 0 {
      switch UInt8(bitPattern: next.pointee) {
      case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
        UInt8(ascii: ";"):
        next += 1
      default:
        // Only SQLite can tell a comment from a statement, so let it compile what is left.
        var statement: OpaquePointer?
        let code = statements.preparation.prepare(connection, next, -1, 0, &statement, nil)
        if let statement { _ = statements.execution.finalize(statement) }
        return code != SQLiteResultCode.ok.rawValue || statement != nil
      }
    }
    return false
  }
}
