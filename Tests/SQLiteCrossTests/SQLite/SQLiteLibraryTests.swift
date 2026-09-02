#if SystemSQLite
  import CSQLite3
  import SQLiteCross
  import Testing

  /// Checks the constants the package declares by hand against the SQLite it was linked against.
  ///
  /// The core module cannot import a SQLite header, which is what lets a caller inject their own
  /// build. That freedom costs us the compiler's agreement that these numbers are right, so this
  /// test buys it back for the system library at least.
  @Test
  func systemConstantsMatchTheSQLiteHeaders() {
    #expect(SQLiteResultCode.ok.rawValue == SQLITE_OK)
    #expect(SQLiteResultCode.error.rawValue == SQLITE_ERROR)
    #expect(SQLiteResultCode.busy.rawValue == SQLITE_BUSY)
    #expect(SQLiteResultCode.locked.rawValue == SQLITE_LOCKED)
    #expect(SQLiteResultCode.readOnly.rawValue == SQLITE_READONLY)
    #expect(SQLiteResultCode.interrupt.rawValue == SQLITE_INTERRUPT)
    #expect(SQLiteResultCode.ioError.rawValue == SQLITE_IOERR)
    #expect(SQLiteResultCode.corrupt.rawValue == SQLITE_CORRUPT)
    #expect(SQLiteResultCode.full.rawValue == SQLITE_FULL)
    #expect(SQLiteResultCode.cantOpen.rawValue == SQLITE_CANTOPEN)
    #expect(SQLiteResultCode.constraint.rawValue == SQLITE_CONSTRAINT)
    #expect(SQLiteResultCode.mismatch.rawValue == SQLITE_MISMATCH)
    #expect(SQLiteResultCode.misuse.rawValue == SQLITE_MISUSE)
    #expect(SQLiteResultCode.notADatabase.rawValue == SQLITE_NOTADB)
    #expect(SQLiteResultCode.row.rawValue == SQLITE_ROW)
    #expect(SQLiteResultCode.done.rawValue == SQLITE_DONE)

    #expect(SQLiteOpenFlags.readOnly.rawValue == SQLITE_OPEN_READONLY)
    #expect(SQLiteOpenFlags.readWrite.rawValue == SQLITE_OPEN_READWRITE)
    #expect(SQLiteOpenFlags.create.rawValue == SQLITE_OPEN_CREATE)
    #expect(SQLiteOpenFlags.uri.rawValue == SQLITE_OPEN_URI)
    #expect(SQLiteOpenFlags.memory.rawValue == SQLITE_OPEN_MEMORY)
    #expect(SQLiteOpenFlags.noMutex.rawValue == SQLITE_OPEN_NOMUTEX)
    #expect(SQLiteOpenFlags.fullMutex.rawValue == SQLITE_OPEN_FULLMUTEX)
    #expect(SQLiteOpenFlags.sharedCache.rawValue == SQLITE_OPEN_SHAREDCACHE)
    #expect(SQLiteOpenFlags.privateCache.rawValue == SQLITE_OPEN_PRIVATECACHE)

    #expect(SQLitePrepareFlags.persistent.rawValue == UInt32(SQLITE_PREPARE_PERSISTENT))
    #expect(SQLitePrepareFlags.normalize.rawValue == UInt32(SQLITE_PREPARE_NORMALIZE))
    #expect(SQLitePrepareFlags.noVirtualTable.rawValue == UInt32(SQLITE_PREPARE_NO_VTAB))

    #expect(SQLiteColumnType.integer.rawValue == SQLITE_INTEGER)
    #expect(SQLiteColumnType.float.rawValue == SQLITE_FLOAT)
    #expect(SQLiteColumnType.text.rawValue == SQLITE_TEXT)
    #expect(SQLiteColumnType.blob.rawValue == SQLITE_BLOB)
    #expect(SQLiteColumnType.null.rawValue == SQLITE_NULL)

    #expect(SQLiteFunctionFlags.utf8.rawValue == SQLITE_UTF8)
    #expect(SQLiteFunctionFlags.deterministic.rawValue == SQLITE_DETERMINISTIC)
    #expect(SQLiteFunctionFlags.directOnly.rawValue == SQLITE_DIRECTONLY)
    #expect(SQLiteFunctionFlags.innocuous.rawValue == SQLITE_INNOCUOUS)

    // `SQLITE_TRANSIENT` is a cast macro, so Swift does not import it. SQLite documents the
    // value as -1 reinterpreted as a destructor, which is what is checked here.
    #expect(unsafeBitCast(SQLiteLibrary.transientDestructor, to: Int.self) == -1)
  }

  /// Drives a query end to end through nothing but the function table.
  ///
  /// No wrapper types exist yet, which is the point: this proves the package can reach SQLite
  /// through an injected table alone.
  @Test
  func functionTableRunsAQueryWithoutAnyWrapperTypes() throws {
    let library = SQLiteLibrary.system
    #expect(library.threadsafe() != 0)
    #expect(library.libversion_number() >= 3_020_000)

    var connection: OpaquePointer?
    let openFlags: SQLiteOpenFlags = [.readWrite, .create, .memory, .noMutex]
    #expect(
      ":memory:".withCString { library.open_v2($0, &connection, openFlags.rawValue, nil) }
        == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.close_v2(connection) }

    var statement: OpaquePointer?
    #expect(
      "SELECT 1, 'hello', 2.5, NULL".withCString {
        library.prepare_v3(connection, $0, -1, 0, &statement, nil)
      } == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.finalize(statement) }

    #expect(library.stmt_readonly(statement) != 0)
    #expect(library.column_count(statement) == 4)
    #expect(library.step(statement) == SQLiteResultCode.row.rawValue)

    #expect(library.column_type(statement, 0) == SQLiteColumnType.integer.rawValue)
    #expect(library.column_int64(statement, 0) == 1)

    #expect(library.column_type(statement, 1) == SQLiteColumnType.text.rawValue)
    let text = try #require(library.column_text(statement, 1))
    let byteCount = Int(library.column_bytes(statement, 1))
    #expect(
      String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self) == "hello"
    )

    #expect(library.column_type(statement, 2) == SQLiteColumnType.float.rawValue)
    #expect(library.column_double(statement, 2) == 2.5)

    #expect(library.column_type(statement, 3) == SQLiteColumnType.null.rawValue)

    #expect(library.step(statement) == SQLiteResultCode.done.rawValue)
  }

  /// Checks that bindings and mutations report through the table the way the drivers will rely on.
  @Test
  func functionTableBindsValuesAndReportsChanges() throws {
    let library = SQLiteLibrary.system
    var connection: OpaquePointer?
    let openFlags: SQLiteOpenFlags = [.readWrite, .create, .memory, .noMutex]
    #expect(
      ":memory:".withCString { library.open_v2($0, &connection, openFlags.rawValue, nil) }
        == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.close_v2(connection) }

    func run(_ sql: String) throws {
      var statement: OpaquePointer?
      #expect(
        sql.withCString { library.prepare_v3(connection, $0, -1, 0, &statement, nil) }
          == SQLiteResultCode.ok.rawValue
      )
      defer { _ = library.finalize(statement) }
      #expect(library.step(statement) == SQLiteResultCode.done.rawValue)
    }

    try run("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")

    var insert: OpaquePointer?
    #expect(
      "INSERT INTO items (title) VALUES (?)".withCString {
        library.prepare_v3(connection, $0, -1, SQLitePrepareFlags.persistent.rawValue, &insert, nil)
      } == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.finalize(insert) }

    #expect(library.stmt_readonly(insert) == 0)
    #expect(library.bind_parameter_count(insert) == 1)
    #expect(
      "Blob".withCString {
        library.bind_text(insert, 1, $0, -1, SQLiteLibrary.transientDestructor)
      } == SQLiteResultCode.ok.rawValue
    )
    #expect(library.step(insert) == SQLiteResultCode.done.rawValue)
    #expect(library.changes(connection) == 1)
    #expect(library.last_insert_rowid(connection) == 1)

    // Resetting and rebinding is exactly what the statement cache will do.
    #expect(library.reset(insert) == SQLiteResultCode.ok.rawValue)
    #expect(library.clear_bindings(insert) == SQLiteResultCode.ok.rawValue)
    #expect(
      "Blob Jr".withCString {
        library.bind_text(insert, 1, $0, -1, SQLiteLibrary.transientDestructor)
      } == SQLiteResultCode.ok.rawValue
    )
    #expect(library.step(insert) == SQLiteResultCode.done.rawValue)
    #expect(library.last_insert_rowid(connection) == 2)
  }

  /// Checks that a failure surfaces a code and a message the error type can carry.
  @Test
  func functionTableReportsErrorsForInvalidSQL() throws {
    let library = SQLiteLibrary.system
    var connection: OpaquePointer?
    let openFlags: SQLiteOpenFlags = [.readWrite, .create, .memory, .noMutex]
    #expect(
      ":memory:".withCString { library.open_v2($0, &connection, openFlags.rawValue, nil) }
        == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.close_v2(connection) }
    #expect(library.extended_result_codes(connection, 1) == SQLiteResultCode.ok.rawValue)

    var statement: OpaquePointer?
    let code = "SELECT * FROM missing".withCString {
      library.prepare_v3(connection, $0, -1, 0, &statement, nil)
    }
    #expect(SQLiteResultCode(rawValue: code).primary == .error)

    let message = String(cString: try #require(library.errmsg(connection)))
    let error = SQLiteError(
      code: SQLiteResultCode(rawValue: library.extended_errcode(connection)),
      message: message,
      sql: "SELECT * FROM missing"
    )
    #expect(error.primaryCode == .error)
    #expect(error.description.contains("missing"))
  }
#endif
