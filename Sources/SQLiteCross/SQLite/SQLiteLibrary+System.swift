#if SystemSQLite
  import CSQLite3

  /// `SQLITE_TRANSIENT` is a cast macro, which Swift does not import; SQLite documents it as `-1`
  /// reinterpreted as a destructor.
  private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  extension SQLiteLibrary {
    /// The SQLite that this package was linked against.
    ///
    /// This is the default for every driver. Supplying a different value is how a caller runs
    /// against their own SQLite build without forking the package; this declaration doubles as the
    /// template for writing one.
    public static let system: Self = {
      var library = Self(
        open_v2: sqlite3_open_v2,
        close_v2: sqlite3_close_v2,
        errmsg: sqlite3_errmsg,
        extended_errcode: sqlite3_extended_errcode,
        extended_result_codes: sqlite3_extended_result_codes,
        busy_timeout: sqlite3_busy_timeout,
        interrupt: sqlite3_interrupt,
        changes: sqlite3_changes,
        last_insert_rowid: sqlite3_last_insert_rowid,
        threadsafe: sqlite3_threadsafe,
        libversion_number: sqlite3_libversion_number,
        prepare_v3: sqlite3_prepare_v3,
        step: sqlite3_step,
        reset: sqlite3_reset,
        finalize: sqlite3_finalize,
        clear_bindings: sqlite3_clear_bindings,
        stmt_readonly: sqlite3_stmt_readonly,
        sql: sqlite3_sql,
        bind_parameter_count: sqlite3_bind_parameter_count,
        bind_null: sqlite3_bind_null,
        bind_int64: sqlite3_bind_int64,
        bind_double: sqlite3_bind_double,
        bind_text: { sqlite3_bind_text($0, $1, $2, $3, SQLITE_TRANSIENT) },
        bind_blob: { sqlite3_bind_blob($0, $1, $2, $3, SQLITE_TRANSIENT) },
        column_count: sqlite3_column_count,
        column_type: sqlite3_column_type,
        column_int64: sqlite3_column_int64,
        column_double: sqlite3_column_double,
        column_text: sqlite3_column_text,
        column_blob: sqlite3_column_blob,
        column_bytes: sqlite3_column_bytes,
        column_name: sqlite3_column_name,
        create_function_v2: sqlite3_create_function_v2
      )
      library.supportsTypedCallbacks = true
      return library
    }()
  }
#endif
