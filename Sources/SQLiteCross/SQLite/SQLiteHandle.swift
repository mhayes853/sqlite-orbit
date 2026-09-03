/// One open `sqlite3 *` and the statements prepared on it.
///
/// The handle is noncopyable because SQLite's connection has exactly one owner: copying the pointer
/// would mean two owners racing to close it. It is never handed out directly; transactions lend it
/// as a nonescapable view that cannot outlive the access it was created for.
struct SQLiteHandle: ~Copyable {
  let pointer: OpaquePointer
  let statements: SQLiteStatementCache

  /// Whether the connection was opened read-only, and so refuses writes on its own.
  let isReadOnly: Bool

  /// The library table, owned here and lent out by pointer.
  ///
  /// Transactions, cursors, and rows are created per access and per row, so copying a table of 33
  /// closures into each of them would put hundreds of bytes of copying on the hottest path in the
  /// package. They borrow this allocation instead, which is sound because every one of them is
  /// nonescapable and so cannot outlive this handle.
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
    self.pointer = pointer
    self.isReadOnly = isReadOnly
    self.libraryStorage = libraryStorage
    self.statements = SQLiteStatementCache(
      library: UnsafePointer(libraryStorage),
      connection: pointer,
      capacity: maximumCachedStatements
    )
  }

  /// Opens and configures a connection.
  ///
  /// Opening is a factory rather than a throwing initializer because a noncopyable value cannot be
  /// partially initialized and then thrown away. That turns out to be the better shape anyway: once
  /// the handle exists, a failed `configure` is cleaned up by its own `deinit`.
  static func open(
    path: DatabasePath,
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
        by: libraryStorage.pointee, on: pointer, code: code, sql: nil
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
    _ = libraryStorage.pointee.extended_result_codes(pointer, 1)
    _ = libraryStorage.pointee.busy_timeout(pointer, configuration.busyTimeoutMilliseconds)
    try execute("PRAGMA foreign_keys = \(configuration.isForeignKeysEnabled ? "ON" : "OFF")")
    try execute("PRAGMA trusted_schema = \(configuration.isTrustedSchemaEnabled ? "ON" : "OFF")")
    // A setup the caller wrote calls whichever SQLite it was handed, so only the package's own
    // typed registrations are held to the linked build.
    guard configuration.library.supportsTypedCallbacks
      || !configuration.connectionSetups.contains(where: \.usesLinkedCallbackABI)
    else {
      throw SQLiteTypedCallbacksUnavailableError()
    }
    for setup in configuration.connectionSetups {
      let code = setup.install(pointer)
      guard code == SQLiteResultCode.ok.rawValue else {
        throw SQLiteError.reported(
          by: libraryStorage.pointee,
          on: pointer,
          code: code,
          sql: nil
        )
      }
    }
    for sql in configuration.setupSQL {
      try execute(sql)
    }
  }

  /// Runs every statement in `sql`, discarding any rows they produce.
  borrowing func execute(_ sql: String) throws {
    try Self.execute(sql, on: pointer, library: library)
  }

  /// The number of rows changed by the most recent statement.
  borrowing func changes() -> Int {
    Int(libraryStorage.pointee.changes(pointer))
  }

  /// The rowid of the most recent successful insert.
  borrowing func lastInsertRowID() -> Int64 {
    libraryStorage.pointee.last_insert_rowid(pointer)
  }

  /// Runs `body` inside a deferred transaction and always rolls it back.
  ///
  /// A read still takes a transaction so that every statement it runs sees one consistent
  /// snapshot, and rolling back is how that snapshot is released — there is nothing to commit.
  borrowing func read<Result: ~Copyable>(
    _ body: (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
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
      try? execute("ROLLBACK")
      throw error
    }
    try execute("ROLLBACK")
    return value
  }

  /// Runs `body` inside an immediate transaction, committing it or rolling it back.
  ///
  /// The transaction is immediate rather than deferred so that a write takes SQLite's write lock
  /// up front. A deferred write would only discover a competing writer partway through, after work
  /// that then has to be thrown away.
  borrowing func write<Result: ~Copyable>(
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try execute("BEGIN IMMEDIATE TRANSACTION")
    let value: Result
    do {
      value = try body(SQLiteWriteTransaction(handle: self))
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
    do {
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
    return value
  }

  /// Runs every statement in `sql` on `connection`, discarding any rows they produce.
  ///
  /// This is the path for schema changes and pragmas, so it accepts several statements at once and
  /// deliberately does not use the statement cache: cached statements are keyed by their whole SQL
  /// text, which a multi-statement batch is not.
  static func execute(
    _ sql: String,
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>
  ) throws {
    // Each statement's length is passed explicitly rather than left to SQLite to measure again.
    try sql.withCString { start in
      let end = start + sql.utf8.count
      var next = start
      while next < end {
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let code = library.pointee.prepare_v3(
          connection, next, Int32(end - next), 0, &statement, &tail
        )
        guard code == SQLiteResultCode.ok.rawValue else {
          throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: sql)
        }
        defer { _ = library.pointee.finalize(statement) }

        // A trailing comment or whitespace prepares nothing; stop rather than spin on it.
        guard statement != nil else { return }
        next = tail ?? end

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
