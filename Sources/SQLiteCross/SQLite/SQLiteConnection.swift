import Synchronization

/// Identifies one open connection.
struct SQLiteConnectionID: Hashable, Sendable {
  let rawValue: Int

  private static let counter = Atomic<Int>(0)

  static func next() -> Self {
    Self(rawValue: counter.wrappingAdd(1, ordering: .relaxed).newValue)
  }
}

/// Builds the error SQLite is currently reporting on a connection.
func sqliteError(
  _ library: borrowing SQLiteLibrary,
  connection: OpaquePointer?,
  code: Int32,
  sql: String?
) -> SQLiteError {
  let message = library.errmsg(connection).map { String(cString: $0) }
  // `extended_errcode` carries the same failure with more detail, but only when it is still
  // describing the failure we were handed.
  let extended = library.extended_errcode(connection)
  let resolved = (extended & 0xff) == (code & 0xff) ? extended : code
  return SQLiteError(code: SQLiteResultCode(rawValue: resolved), message: message, sql: sql)
}

/// One open SQLite connection.
///
/// The connection is noncopyable because SQLite's `sqlite3 *` has exactly one owner: copying the
/// pointer would mean two owners racing to close it. Its handle is never handed out directly;
/// transactions lend it as a nonescapable view that cannot outlive the access it was created for.
struct SQLiteConnection: ~Copyable {
  let id: SQLiteConnectionID
  let handle: OpaquePointer
  let statements: SQLiteStatementCache

  /// The library table, owned here and lent out by pointer.
  ///
  /// Transactions, cursors, and rows are created per access and per row, so copying a table of 33
  /// closures into each of them would put hundreds of bytes of copying on the hottest path in the
  /// package. They borrow this allocation instead, which is sound because every one of them is
  /// nonescapable and so cannot outlive this connection.
  private let libraryStorage: UnsafeMutablePointer<SQLiteLibrary>

  var library: UnsafePointer<SQLiteLibrary> {
    UnsafePointer(libraryStorage)
  }

  private init(
    handle: OpaquePointer,
    libraryStorage: UnsafeMutablePointer<SQLiteLibrary>,
    maximumCachedStatements: Int
  ) {
    self.id = .next()
    self.handle = handle
    self.libraryStorage = libraryStorage
    self.statements = SQLiteStatementCache(
      library: UnsafePointer(libraryStorage),
      connection: handle,
      capacity: maximumCachedStatements
    )
  }

  /// Opens and configures a connection.
  ///
  /// Opening is a factory rather than a throwing initializer because a noncopyable value cannot be
  /// partially initialized and then thrown away. That turns out to be the better shape anyway: once
  /// the connection exists, a failed `configure` is cleaned up by its own `deinit`.
  static func open(
    path: String,
    flags: SQLiteOpenFlags,
    configuration: SQLiteConfiguration
  ) throws -> SQLiteConnection {
    let libraryStorage = UnsafeMutablePointer<SQLiteLibrary>.allocate(capacity: 1)
    libraryStorage.initialize(to: configuration.library)

    var handle: OpaquePointer?
    let code = path.withCString {
      libraryStorage.pointee.open_v2($0, &handle, flags.rawValue, nil)
    }
    guard code == SQLiteResultCode.ok.rawValue, let handle else {
      // SQLite hands back a connection even for most failed opens, and it is the caller's to close.
      let error = sqliteError(libraryStorage.pointee, connection: handle, code: code, sql: nil)
      if let handle {
        _ = libraryStorage.pointee.close_v2(handle)
      }
      libraryStorage.deinitialize(count: 1)
      libraryStorage.deallocate()
      throw error
    }

    let connection = SQLiteConnection(
      handle: handle,
      libraryStorage: libraryStorage,
      maximumCachedStatements: configuration.maximumCachedStatements
    )
    try connection.configure(configuration)
    return connection
  }

  deinit {
    // Statements are finalized before the table allocation goes away, because finalizing needs it.
    statements.finalizeAll()
    _ = libraryStorage.pointee.close_v2(handle)
    libraryStorage.deinitialize(count: 1)
    libraryStorage.deallocate()
  }

  private borrowing func configure(_ configuration: SQLiteConfiguration) throws {
    _ = libraryStorage.pointee.extended_result_codes(handle, 1)
    _ = libraryStorage.pointee.busy_timeout(handle, configuration.busyTimeoutMilliseconds)
    try execute("PRAGMA foreign_keys = \(configuration.isForeignKeysEnabled ? "ON" : "OFF")")
    try execute("PRAGMA trusted_schema = \(configuration.isTrustedSchemaEnabled ? "ON" : "OFF")")
    for sql in configuration.setupSQL {
      try execute(sql)
    }
  }

  /// Runs every statement in `sql`, discarding any rows they produce.
  ///
  /// This is the path for schema changes and pragmas, so it accepts several statements at once and
  /// deliberately does not use the statement cache.
  borrowing func execute(_ sql: String) throws {
    try sql.withCString { start in
      var next: UnsafePointer<CChar>? = start
      while let current = next, current.pointee != 0 {
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let code = libraryStorage.pointee.prepare_v3(handle, current, -1, 0, &statement, &tail)
        guard code == SQLiteResultCode.ok.rawValue else {
          throw sqliteError(libraryStorage.pointee, connection: handle, code: code, sql: sql)
        }
        defer { _ = libraryStorage.pointee.finalize(statement) }

        // A trailing comment or whitespace prepares nothing; stop rather than spin on it.
        guard statement != nil else { return }
        next = tail

        var stepCode = libraryStorage.pointee.step(statement)
        while stepCode == SQLiteResultCode.row.rawValue {
          stepCode = libraryStorage.pointee.step(statement)
        }
        guard stepCode == SQLiteResultCode.done.rawValue else {
          throw sqliteError(libraryStorage.pointee, connection: handle, code: stepCode, sql: sql)
        }
      }
    }
  }

  /// The number of rows changed by the most recent statement.
  borrowing func changes() -> Int {
    Int(libraryStorage.pointee.changes(handle))
  }

  /// The rowid of the most recent successful insert.
  borrowing func lastInsertRowID() -> Int64 {
    libraryStorage.pointee.last_insert_rowid(handle)
  }

  /// Aborts whatever query is running on this connection.
  ///
  /// This is safe to call from another thread, which is what lets a cancelled task stop a scan
  /// that has already started.
  borrowing func interrupt() {
    libraryStorage.pointee.interrupt(handle)
  }
}
