#if SystemSQLite
  import CSQLite3
  @testable import SQLiteOrbit
  import Testing

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
  }

  @Test
  func resultCodesReportSuccessThroughTheirExtendedBits() {
    #expect(SQLiteResultCode.ok.isSuccess)
    #expect(SQLiteResultCode.row.isSuccess)
    #expect(SQLiteResultCode.done.isSuccess)
    // `SQLITE_OK_LOAD_PERMANENTLY` is 256; `SQLITE_BUSY_SNAPSHOT` is 517.
    #expect(SQLiteResultCode(rawValue: 256).isSuccess)
    #expect(SQLiteResultCode(rawValue: 256).primary == .ok)
    #expect(!SQLiteResultCode.busy.isSuccess)
    #expect(!SQLiteResultCode(rawValue: 517).isSuccess)
    #expect(SQLiteResultCode(rawValue: 517).primary == .busy)
  }

  @Test
  func unavailableLibraryFeaturesAreTypedAndExtensible() {
    let feature = SQLiteLibraryFeature(rawValue: "extension loading")
    let error = SQLiteFeatureUnavailableError(libraryName: "custom", feature: feature)

    #expect(error.feature == feature)
    #expect(error.description == "custom does not support SQLite's extension loading.")
  }

  @Test
  func functionTableRunsAQueryWithoutAnyWrapperTypes() throws {
    let library = SQLiteLibrary.system
    #expect(library.runtime.threadsafe() != 0)
    #expect(library.runtime.versionNumber() >= 3_020_000)

    var connection: OpaquePointer?
    let openFlags: SQLiteOpenFlags = [.readWrite, .create, .memory, .noMutex]
    #expect(
      ":memory:".withCString { library.connections.open($0, &connection, openFlags.rawValue, nil) }
        == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.connections.close(connection) }

    var statement: OpaquePointer?
    #expect(
      "SELECT 1, 'hello', 2.5, NULL"
        .withCString {
          library.statements.preparation.prepare(connection, $0, -1, 0, &statement, nil)
        } == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.statements.execution.finalize(statement) }

    #expect(library.statements.inspection.isReadOnly(statement) != 0)
    #expect(library.columns.count(statement) == 4)
    #expect(library.statements.execution.step(statement) == SQLiteResultCode.row.rawValue)

    #expect(library.columns.type(statement, 0) == SQLiteColumnType.integer.rawValue)
    #expect(library.columns.int64(statement, 0) == 1)

    #expect(library.columns.type(statement, 1) == SQLiteColumnType.text.rawValue)
    let text = try #require(library.columns.text(statement, 1))
    let byteCount = Int(library.columns.byteCount(statement, 1))
    #expect(
      String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self) == "hello"
    )

    #expect(library.columns.type(statement, 2) == SQLiteColumnType.float.rawValue)
    #expect(library.columns.double(statement, 2) == 2.5)

    #expect(library.columns.type(statement, 3) == SQLiteColumnType.null.rawValue)

    #expect(library.statements.execution.step(statement) == SQLiteResultCode.done.rawValue)
  }

  @Test
  func macroBuildsATableFromAQualifiedModule() {
    let library = #sqliteLibrary(module: "CSQLite3")

    #expect(library.runtime.versionNumber() == SQLiteLibrary.system.runtime.versionNumber())
    #expect(library.encryption == nil)
  }

  @Test
  func functionTableBindsValuesAndReportsChanges() throws {
    let library = SQLiteLibrary.system
    var connection: OpaquePointer?
    let openFlags: SQLiteOpenFlags = [.readWrite, .create, .memory, .noMutex]
    #expect(
      ":memory:".withCString { library.connections.open($0, &connection, openFlags.rawValue, nil) }
        == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.connections.close(connection) }

    func run(_ sql: String) throws {
      var statement: OpaquePointer?
      #expect(
        sql.withCString {
          library.statements.preparation.prepare(connection, $0, -1, 0, &statement, nil)
        }
          == SQLiteResultCode.ok.rawValue
      )
      defer { _ = library.statements.execution.finalize(statement) }
      #expect(library.statements.execution.step(statement) == SQLiteResultCode.done.rawValue)
    }

    try run("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")

    var insert: OpaquePointer?
    #expect(
      "INSERT INTO items (title) VALUES (?)"
        .withCString {
          library.statements.preparation.prepare(
            connection,
            $0,
            -1,
            SQLitePrepareFlags.persistent.rawValue,
            &insert,
            nil
          )
        } == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.statements.execution.finalize(insert) }

    #expect(library.statements.inspection.isReadOnly(insert) == 0)
    #expect(library.bindings.parameterCount(insert) == 1)
    #expect(
      "Blob"
        .withCString {
          library.bindings.text(insert, 1, $0, -1)
        } == SQLiteResultCode.ok.rawValue
    )
    #expect(library.statements.execution.step(insert) == SQLiteResultCode.done.rawValue)
    #expect(library.connections.changes(connection) == 1)
    #expect(library.connections.lastInsertedRowID(connection) == 1)

    // Resetting and rebinding is exactly what the statement cache will do.
    #expect(library.statements.execution.reset(insert) == SQLiteResultCode.ok.rawValue)
    #expect(library.statements.execution.clearBindings(insert) == SQLiteResultCode.ok.rawValue)
    #expect(
      "Blob Jr"
        .withCString {
          library.bindings.text(insert, 1, $0, -1)
        } == SQLiteResultCode.ok.rawValue
    )
    #expect(library.statements.execution.step(insert) == SQLiteResultCode.done.rawValue)
    #expect(library.connections.lastInsertedRowID(connection) == 2)
  }

  @Test
  func functionTableEntryPointsCanBeInterposedPerInstance() throws {
    let preparedSQL = Lock<[String]>([])
    var library = SQLiteLibrary.system
    let base = SQLiteLibrary.system
    library.statements.preparation.prepare = { connection, sql, byteCount, flags, statement, tail in
      if let sql {
        preparedSQL.withLock { $0.append(String(cString: sql)) }
      }
      return base.statements.preparation.prepare(connection, sql, byteCount, flags, statement, tail)
    }

    // A second table wrapping the same system library keeps its own state.
    let failingStep = Lock(0)
    var faulty = SQLiteLibrary.system
    faulty.statements.execution.step = { statement in
      failingStep.withLock { $0 += 1 }
      return SQLiteResultCode.busy.rawValue
    }

    var connection: OpaquePointer?
    let openFlags: SQLiteOpenFlags = [.readWrite, .create, .memory, .noMutex]
    #expect(
      ":memory:".withCString { library.connections.open($0, &connection, openFlags.rawValue, nil) }
        == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.connections.close(connection) }

    var statement: OpaquePointer?
    #expect(
      "SELECT 1"
        .withCString {
          library.statements.preparation.prepare(connection, $0, -1, 0, &statement, nil)
        }
        == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.statements.execution.finalize(statement) }

    #expect(preparedSQL.withLock { $0 } == ["SELECT 1"])
    // The unwrapped table is unaffected, and the faulty one reports its injected failure.
    #expect(library.statements.execution.step(statement) == SQLiteResultCode.row.rawValue)
    #expect(faulty.statements.execution.step(statement) == SQLiteResultCode.busy.rawValue)
    #expect(failingStep.withLock { $0 } == 1)
  }

  @Test
  func functionTableReportsErrorsForInvalidSQL() throws {
    let library = SQLiteLibrary.system
    var connection: OpaquePointer?
    let openFlags: SQLiteOpenFlags = [.readWrite, .create, .memory, .noMutex]
    #expect(
      ":memory:".withCString { library.connections.open($0, &connection, openFlags.rawValue, nil) }
        == SQLiteResultCode.ok.rawValue
    )
    defer { _ = library.connections.close(connection) }
    #expect(
      library.connections.setExtendedResultCodes(connection, 1) == SQLiteResultCode.ok.rawValue
    )

    var statement: OpaquePointer?
    let code = "SELECT * FROM missing"
      .withCString {
        library.statements.preparation.prepare(connection, $0, -1, 0, &statement, nil)
      }
    #expect(SQLiteResultCode(rawValue: code).primary == .error)

    let message = String(cString: try #require(library.connections.errorMessage(connection)))
    let error = SQLiteError(
      code: SQLiteResultCode(rawValue: library.connections.extendedErrorCode(connection)),
      message: message,
      sql: "SELECT * FROM missing"
    )
    #expect(error.primaryCode == .error)
    #expect(error.description.contains("missing"))
  }
#endif
