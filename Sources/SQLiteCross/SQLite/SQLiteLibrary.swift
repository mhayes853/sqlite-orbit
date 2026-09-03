/// The destructor SQLite calls to release a value or context it was handed.
public typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// A table of the SQLite entry points ``SQLiteCross`` needs.
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
public struct SQLiteLibrary: Sendable {

  /// Whether Swift callback registration can use the linked SQLite callback ABI with connections
  /// opened through this table. Preserved when individual entry points are interposed.
  var supportsTypedCallbacks = false

  // MARK: - Connections

  public var open_v2:
    @Sendable (
      UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
    ) -> Int32
  public var close_v2: @Sendable (OpaquePointer?) -> Int32
  public var errmsg: @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?
  public var extended_errcode: @Sendable (OpaquePointer?) -> Int32
  public var extended_result_codes: @Sendable (OpaquePointer?, Int32) -> Int32
  public var busy_timeout: @Sendable (OpaquePointer?, Int32) -> Int32

  /// Interrupts the query running on a connection.
  ///
  /// This is the one entry point that is called from a thread other than the connection's own,
  /// which is what lets a cancelled task abort a long-running scan.
  public var interrupt: @Sendable (OpaquePointer?) -> Void
  public var changes: @Sendable (OpaquePointer?) -> Int32
  public var last_insert_rowid: @Sendable (OpaquePointer?) -> Int64
  public var threadsafe: @Sendable () -> Int32
  public var libversion_number: @Sendable () -> Int32

  // MARK: - Statements

  public var prepare_v3:
    @Sendable (
      OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
      UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
    ) -> Int32
  public var step: @Sendable (OpaquePointer?) -> Int32
  public var reset: @Sendable (OpaquePointer?) -> Int32
  public var finalize: @Sendable (OpaquePointer?) -> Int32
  public var clear_bindings: @Sendable (OpaquePointer?) -> Int32
  public var stmt_readonly: @Sendable (OpaquePointer?) -> Int32
  public var sql: @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?

  // MARK: - Bindings

  public var bind_parameter_count: @Sendable (OpaquePointer?) -> Int32
  public var bind_null: @Sendable (OpaquePointer?, Int32) -> Int32
  public var bind_int64: @Sendable (OpaquePointer?, Int32, Int64) -> Int32
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

  public var column_count: @Sendable (OpaquePointer?) -> Int32
  public var column_type: @Sendable (OpaquePointer?, Int32) -> Int32
  public var column_int64: @Sendable (OpaquePointer?, Int32) -> Int64
  public var column_double: @Sendable (OpaquePointer?, Int32) -> Double
  public var column_text: @Sendable (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
  public var column_blob: @Sendable (OpaquePointer?, Int32) -> UnsafeRawPointer?
  public var column_bytes: @Sendable (OpaquePointer?, Int32) -> Int32
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

  public init(
    open_v2: @escaping @Sendable (
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
    threadsafe: @escaping @Sendable () -> Int32,
    libversion_number: @escaping @Sendable () -> Int32,
    prepare_v3: @escaping @Sendable (
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
    create_function_v2: @escaping @Sendable (
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
