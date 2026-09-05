#if SystemSQLite
  import CSQLite3
#endif

/// The destructor SQLite calls to release a value or context it was handed.
///
/// ```swift
/// _ = sqlite3_bind_text(statement, 1, bytes, count, SQLiteLibrary.transientDestructor)
/// ```
public typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

extension SQLiteLibrary {
  /// SQLite's `SQLITE_TRANSIENT`: the destructor that tells SQLite to copy the bytes it was handed
  /// rather than borrow them.
  ///
  /// SQLite spells this as a cast macro, which Swift does not import, so a caller building a table
  /// against their own SQLite build has no way to name it. It is documented as `-1` reinterpreted
  /// as a destructor, and is what ``SQLiteLibrary/bind_text`` and ``SQLiteLibrary/bind_blob`` must
  /// pass: the buffers this package binds live only for the call.
  public static let transientDestructor = unsafeBitCast(-1, to: SQLiteDestructor.self)
}

/// A table of the SQLite entry points ``SQLiteOrbit`` needs.
///
/// The package calls SQLite only through this table, and the core module imports no SQLite header,
/// so a caller can supply any build of SQLite — SQLCipher, a custom amalgamation, or one with
/// extensions compiled in — without forking the package. ``SQLiteLibrary/system`` is available when
/// the `SystemSQLite` trait is enabled, which it is by default.
///
/// Every member is a mutable closure, so a caller can interpose on one entry point while leaving
/// the rest alone — wrapping ``prepare_v3`` to count statement preparations, or ``step`` to inject
/// `SQLITE_BUSY`. C functions convert to these closures implicitly, so a table built from a real
/// SQLite costs nothing beyond the call itself.
///
/// A connection owns one library value and lends it out by pointer, so the table is never copied
/// onto a query's hot path.
///
/// ```swift
/// var library = SQLiteLibrary.system
/// library.step = { statement in
///   preparedSteps.withLock { $0 += 1 }
///   return SQLiteLibrary.system.step(statement)
/// }
/// let driver = try SQLiteQueue(
///   path: ":memory:",
///   configuration: SQLiteConfiguration(library: library)
/// )
/// ```
public struct SQLiteLibrary: Sendable {

  /// Whether this table's connections may be handed the static C callbacks that
  /// ``SQLiteConfiguration/register(function:)-(some ScalarDatabaseFunction & Sendable)`` and its
  /// siblings install.
  ///
  /// Those callbacks read values, results, and contexts through the SQLite this package was linked
  /// against rather than through this table, so handing one a value belonging to another build
  /// would read one SQLite's memory with another's layout. ``system`` is the only table this
  /// package can vouch for, so it is the only one that sets this; every other table refuses typed
  /// registration with ``SQLiteTypedCallbacksUnavailableError``. Interposing individual entry
  /// points preserves the flag, because an interposed `system` is still the linked SQLite.
  ///
  /// Set this only for a table whose `sqlite3_*` functions come from the very build this package
  /// linked against — a differently named export of the same library, for instance. Setting it for
  /// a genuinely separate build is undefined behavior.
  public var supportsTypedCallbacks = false

  // MARK: - Connections

  /// Opens a connection: `sqlite3_open_v2`.
  public var open_v2:
    @Sendable (
      UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
    ) -> Int32
  /// Closes a connection once its statements are finalized: `sqlite3_close_v2`.
  public var close_v2: @Sendable (OpaquePointer?) -> Int32
  /// The connection's current error message: `sqlite3_errmsg`.
  public var errmsg: @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?
  /// The connection's current extended result code: `sqlite3_extended_errcode`.
  public var extended_errcode: @Sendable (OpaquePointer?) -> Int32
  /// Turns extended result codes on or off: `sqlite3_extended_result_codes`.
  public var extended_result_codes: @Sendable (OpaquePointer?, Int32) -> Int32
  /// Sets how long a locked connection waits before reporting `SQLITE_BUSY`:
  /// `sqlite3_busy_timeout`.
  public var busy_timeout: @Sendable (OpaquePointer?, Int32) -> Int32

  /// Interrupts the query running on a connection.
  ///
  /// This is the one entry point that is called from a thread other than the connection's own,
  /// which is what lets a cancelled task abort a long-running scan.
  public var interrupt: @Sendable (OpaquePointer?) -> Void
  /// Rows changed by the most recent statement: `sqlite3_changes`.
  public var changes: @Sendable (OpaquePointer?) -> Int32
  /// The rowid of the most recent successful insert: `sqlite3_last_insert_rowid`.
  public var last_insert_rowid: @Sendable (OpaquePointer?) -> Int64

  /// Whether the connection is in autocommit mode, and so has no transaction open.
  ///
  /// A statement can fail partway through ending a transaction, and this is the only way to ask
  /// the connection whether one is still open rather than guess from the failure.
  public var get_autocommit: @Sendable (OpaquePointer?) -> Int32
  /// The threading mode SQLite was compiled with: `sqlite3_threadsafe`.
  public var threadsafe: @Sendable () -> Int32
  /// The library's version as a number: `sqlite3_libversion_number`.
  public var libversion_number: @Sendable () -> Int32

  // MARK: - Statements

  /// Compiles one statement and reports where it stopped: `sqlite3_prepare_v3`.
  public var prepare_v3:
    @Sendable (
      OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
      UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
    ) -> Int32
  /// Advances a statement to its next row or to completion: `sqlite3_step`.
  public var step: @Sendable (OpaquePointer?) -> Int32
  /// Rewinds a statement so it can run again, keeping its bindings: `sqlite3_reset`.
  public var reset: @Sendable (OpaquePointer?) -> Int32
  /// Destroys a statement: `sqlite3_finalize`.
  public var finalize: @Sendable (OpaquePointer?) -> Int32
  /// Clears a statement's parameter bindings: `sqlite3_clear_bindings`.
  public var clear_bindings: @Sendable (OpaquePointer?) -> Int32
  /// Whether a statement only reads: `sqlite3_stmt_readonly`.
  public var stmt_readonly: @Sendable (OpaquePointer?) -> Int32
  /// The SQL a statement was prepared from: `sqlite3_sql`.
  public var sql: @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?

  // MARK: - Bindings

  /// How many parameters a statement has: `sqlite3_bind_parameter_count`.
  public var bind_parameter_count: @Sendable (OpaquePointer?) -> Int32
  /// Binds SQL NULL: `sqlite3_bind_null`.
  public var bind_null: @Sendable (OpaquePointer?, Int32) -> Int32
  /// Binds a 64-bit integer: `sqlite3_bind_int64`.
  public var bind_int64: @Sendable (OpaquePointer?, Int32, Int64) -> Int32
  /// Binds a floating-point value: `sqlite3_bind_double`.
  public var bind_double: @Sendable (OpaquePointer?, Int32, Double) -> Int32
  /// Binds a copy of the text at a pointer, which need only stay valid for the call.
  ///
  /// SQLite's own `sqlite3_bind_text` takes a destructor to say whether it may borrow the bytes.
  /// The table does not: the buffers this package binds live only for the call, so its entry point
  /// always copies, which is `SQLITE_TRANSIENT` in a build's own terms.
  public var bind_text: @Sendable (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32) -> Int32

  /// Binds a copy of the bytes at a pointer, which need only stay valid for the call.
  public var bind_blob: @Sendable (OpaquePointer?, Int32, UnsafeRawPointer?, Int32) -> Int32

  // MARK: - Columns

  /// How many columns a result row has: `sqlite3_column_count`.
  public var column_count: @Sendable (OpaquePointer?) -> Int32
  /// A column's storage class, one of ``SQLiteColumnType``: `sqlite3_column_type`.
  public var column_type: @Sendable (OpaquePointer?, Int32) -> Int32
  /// Reads a column as a 64-bit integer: `sqlite3_column_int64`.
  public var column_int64: @Sendable (OpaquePointer?, Int32) -> Int64
  /// Reads a column as a floating-point value: `sqlite3_column_double`.
  public var column_double: @Sendable (OpaquePointer?, Int32) -> Double
  /// Reads a column as UTF-8 text: `sqlite3_column_text`.
  public var column_text: @Sendable (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
  /// Reads a column as bytes: `sqlite3_column_blob`.
  public var column_blob: @Sendable (OpaquePointer?, Int32) -> UnsafeRawPointer?
  /// The byte count of the text or blob just read: `sqlite3_column_bytes`.
  public var column_bytes: @Sendable (OpaquePointer?, Int32) -> Int32
  /// A column's name: `sqlite3_column_name`.
  public var column_name: @Sendable (OpaquePointer?, Int32) -> UnsafePointer<CChar>?

  // MARK: - Custom functions

  /// Registers a custom SQL function.
  ///
  /// This is the entry point most often wanted by a caller who supplied their own SQLite build, so
  /// it is part of the table even though the package does not call it itself.
  public var create_function_v2:
    @Sendable (
      OpaquePointer?, UnsafePointer<CChar>?, Int32, Int32, UnsafeMutableRawPointer?,
      (@convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void)?,
      (@convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void)?,
      (@convention(c) (OpaquePointer?) -> Void)?,
      SQLiteDestructor?
    ) -> Int32

  /// Creates a table from a SQLite build's entry points.
  ///
  /// Each parameter is the correspondingly named `sqlite3_*` function. `bind_text` and `bind_blob`
  /// must copy the bytes they are handed — pass ``transientDestructor`` to the build's own
  /// `sqlite3_bind_text` and `sqlite3_bind_blob` — because the buffers this package binds live
  /// only for the call.
  ///
  /// ```swift
  /// let library = SQLiteLibrary(
  ///   open_v2: myBuild_open_v2,
  ///   // ...
  ///   bind_text: { myBuild_bind_text($0, $1, $2, $3, SQLiteLibrary.transientDestructor) },
  ///   bind_blob: { myBuild_bind_blob($0, $1, $2, $3, SQLiteLibrary.transientDestructor) },
  ///   // ...
  /// )
  /// ```
  public init(
    open_v2:
      @escaping @Sendable (
        UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
      ) -> Int32,
    close_v2: @escaping @Sendable (OpaquePointer?) -> Int32,
    errmsg: @escaping @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?,
    extended_errcode: @escaping @Sendable (OpaquePointer?) -> Int32,
    extended_result_codes: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
    busy_timeout: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
    interrupt: @escaping @Sendable (OpaquePointer?) -> Void,
    changes: @escaping @Sendable (OpaquePointer?) -> Int32,
    last_insert_rowid: @escaping @Sendable (OpaquePointer?) -> Int64,
    get_autocommit: @escaping @Sendable (OpaquePointer?) -> Int32,
    threadsafe: @escaping @Sendable () -> Int32,
    libversion_number: @escaping @Sendable () -> Int32,
    prepare_v3:
      @escaping @Sendable (
        OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
        UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
      ) -> Int32,
    step: @escaping @Sendable (OpaquePointer?) -> Int32,
    reset: @escaping @Sendable (OpaquePointer?) -> Int32,
    finalize: @escaping @Sendable (OpaquePointer?) -> Int32,
    clear_bindings: @escaping @Sendable (OpaquePointer?) -> Int32,
    stmt_readonly: @escaping @Sendable (OpaquePointer?) -> Int32,
    sql: @escaping @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?,
    bind_parameter_count: @escaping @Sendable (OpaquePointer?) -> Int32,
    bind_null: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
    bind_int64: @escaping @Sendable (OpaquePointer?, Int32, Int64) -> Int32,
    bind_double: @escaping @Sendable (OpaquePointer?, Int32, Double) -> Int32,
    bind_text: @escaping @Sendable (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32) -> Int32,
    bind_blob: @escaping @Sendable (OpaquePointer?, Int32, UnsafeRawPointer?, Int32) -> Int32,
    column_count: @escaping @Sendable (OpaquePointer?) -> Int32,
    column_type: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
    column_int64: @escaping @Sendable (OpaquePointer?, Int32) -> Int64,
    column_double: @escaping @Sendable (OpaquePointer?, Int32) -> Double,
    column_text: @escaping @Sendable (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?,
    column_blob: @escaping @Sendable (OpaquePointer?, Int32) -> UnsafeRawPointer?,
    column_bytes: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
    column_name: @escaping @Sendable (OpaquePointer?, Int32) -> UnsafePointer<CChar>?,
    create_function_v2:
      @escaping @Sendable (
        OpaquePointer?, UnsafePointer<CChar>?, Int32, Int32, UnsafeMutableRawPointer?,
        (@convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void)?,
        (@convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void)?,
        (@convention(c) (OpaquePointer?) -> Void)?,
        SQLiteDestructor?
      ) -> Int32
  ) {
    self.open_v2 = open_v2
    self.close_v2 = close_v2
    self.errmsg = errmsg
    self.extended_errcode = extended_errcode
    self.extended_result_codes = extended_result_codes
    self.busy_timeout = busy_timeout
    self.interrupt = interrupt
    self.changes = changes
    self.last_insert_rowid = last_insert_rowid
    self.get_autocommit = get_autocommit
    self.threadsafe = threadsafe
    self.libversion_number = libversion_number
    self.prepare_v3 = prepare_v3
    self.step = step
    self.reset = reset
    self.finalize = finalize
    self.clear_bindings = clear_bindings
    self.stmt_readonly = stmt_readonly
    self.sql = sql
    self.bind_parameter_count = bind_parameter_count
    self.bind_null = bind_null
    self.bind_int64 = bind_int64
    self.bind_double = bind_double
    self.bind_text = bind_text
    self.bind_blob = bind_blob
    self.column_count = column_count
    self.column_type = column_type
    self.column_int64 = column_int64
    self.column_double = column_double
    self.column_text = column_text
    self.column_blob = column_blob
    self.column_bytes = column_bytes
    self.column_name = column_name
    self.create_function_v2 = create_function_v2
  }
}

#if SystemSQLite
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
        get_autocommit: sqlite3_get_autocommit,
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
        bind_text: { sqlite3_bind_text($0, $1, $2, $3, Self.transientDestructor) },
        bind_blob: { sqlite3_bind_blob($0, $1, $2, $3, Self.transientDestructor) },
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
