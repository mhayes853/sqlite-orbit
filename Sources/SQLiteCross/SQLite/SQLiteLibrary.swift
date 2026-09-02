/// The destructor SQLite calls to release a bound text or blob value.
public typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// A table of the SQLite entry points ``SQLiteCross`` needs.
///
/// The package calls SQLite only through this table, and the core module imports no SQLite header,
/// so a caller can supply any build of SQLite — SQLCipher, a custom amalgamation, or one with
/// extensions compiled in — without forking the package. ``SQLiteLibrary/system`` is available when
/// the `SystemSQLite` trait is enabled, which it is by default.
///
/// A library value is copied into every connection it opens, so it must remain valid for as long as
/// those connections are open.
public struct SQLiteLibrary: Sendable {

  // MARK: - Connections

  public var open_v2:
    @convention(c) (
      UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
    ) -> Int32
  public var close_v2: @convention(c) (OpaquePointer?) -> Int32
  public var errmsg: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
  public var extended_errcode: @convention(c) (OpaquePointer?) -> Int32
  public var extended_result_codes: @convention(c) (OpaquePointer?, Int32) -> Int32
  public var busy_timeout: @convention(c) (OpaquePointer?, Int32) -> Int32

  /// Interrupts the query running on a connection.
  ///
  /// This is the one entry point that is called from a thread other than the connection's own,
  /// which is what lets a cancelled task abort a long-running scan.
  public var interrupt: @convention(c) (OpaquePointer?) -> Void
  public var changes: @convention(c) (OpaquePointer?) -> Int32
  public var last_insert_rowid: @convention(c) (OpaquePointer?) -> Int64
  public var threadsafe: @convention(c) () -> Int32
  public var libversion_number: @convention(c) () -> Int32

  // MARK: - Statements

  public var prepare_v3:
    @convention(c) (
      OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
      UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
    ) -> Int32
  public var step: @convention(c) (OpaquePointer?) -> Int32
  public var reset: @convention(c) (OpaquePointer?) -> Int32
  public var finalize: @convention(c) (OpaquePointer?) -> Int32
  public var clear_bindings: @convention(c) (OpaquePointer?) -> Int32
  public var stmt_readonly: @convention(c) (OpaquePointer?) -> Int32
  public var sql: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

  // MARK: - Bindings

  public var bind_parameter_count: @convention(c) (OpaquePointer?) -> Int32
  public var bind_null: @convention(c) (OpaquePointer?, Int32) -> Int32
  public var bind_int64: @convention(c) (OpaquePointer?, Int32, Int64) -> Int32
  public var bind_double: @convention(c) (OpaquePointer?, Int32, Double) -> Int32
  public var bind_text:
    @convention(c) (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32, SQLiteDestructor?) -> Int32
  public var bind_blob:
    @convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?, Int32, SQLiteDestructor?) -> Int32

  // MARK: - Columns

  public var column_count: @convention(c) (OpaquePointer?) -> Int32
  public var column_type: @convention(c) (OpaquePointer?, Int32) -> Int32
  public var column_int64: @convention(c) (OpaquePointer?, Int32) -> Int64
  public var column_double: @convention(c) (OpaquePointer?, Int32) -> Double
  public var column_text: @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
  public var column_blob: @convention(c) (OpaquePointer?, Int32) -> UnsafeRawPointer?
  public var column_bytes: @convention(c) (OpaquePointer?, Int32) -> Int32
  public var column_name: @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?

  // MARK: - Custom functions

  /// Registers a custom SQL function.
  ///
  /// This is the entry point most often wanted by a caller who supplied their own SQLite build, so
  /// it is part of the table even though the package does not call it itself.
  public var create_function_v2:
    @convention(c) (
      OpaquePointer?, UnsafePointer<CChar>?, Int32, Int32, UnsafeMutableRawPointer?,
      (@convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void)?,
      (@convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void)?,
      (@convention(c) (OpaquePointer?) -> Void)?,
      SQLiteDestructor?
    ) -> Int32

  public init(
    open_v2: @escaping @convention(c) (
      UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
    ) -> Int32,
    close_v2: @escaping @convention(c) (OpaquePointer?) -> Int32,
    errmsg: @escaping @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?,
    extended_errcode: @escaping @convention(c) (OpaquePointer?) -> Int32,
    extended_result_codes: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
    busy_timeout: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
    interrupt: @escaping @convention(c) (OpaquePointer?) -> Void,
    changes: @escaping @convention(c) (OpaquePointer?) -> Int32,
    last_insert_rowid: @escaping @convention(c) (OpaquePointer?) -> Int64,
    threadsafe: @escaping @convention(c) () -> Int32,
    libversion_number: @escaping @convention(c) () -> Int32,
    prepare_v3: @escaping @convention(c) (
      OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
      UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
    ) -> Int32,
    step: @escaping @convention(c) (OpaquePointer?) -> Int32,
    reset: @escaping @convention(c) (OpaquePointer?) -> Int32,
    finalize: @escaping @convention(c) (OpaquePointer?) -> Int32,
    clear_bindings: @escaping @convention(c) (OpaquePointer?) -> Int32,
    stmt_readonly: @escaping @convention(c) (OpaquePointer?) -> Int32,
    sql: @escaping @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?,
    bind_parameter_count: @escaping @convention(c) (OpaquePointer?) -> Int32,
    bind_null: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
    bind_int64: @escaping @convention(c) (OpaquePointer?, Int32, Int64) -> Int32,
    bind_double: @escaping @convention(c) (OpaquePointer?, Int32, Double) -> Int32,
    bind_text: @escaping @convention(c) (
      OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32, SQLiteDestructor?
    ) -> Int32,
    bind_blob: @escaping @convention(c) (
      OpaquePointer?, Int32, UnsafeRawPointer?, Int32, SQLiteDestructor?
    ) -> Int32,
    column_count: @escaping @convention(c) (OpaquePointer?) -> Int32,
    column_type: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
    column_int64: @escaping @convention(c) (OpaquePointer?, Int32) -> Int64,
    column_double: @escaping @convention(c) (OpaquePointer?, Int32) -> Double,
    column_text: @escaping @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?,
    column_blob: @escaping @convention(c) (OpaquePointer?, Int32) -> UnsafeRawPointer?,
    column_bytes: @escaping @convention(c) (OpaquePointer?, Int32) -> Int32,
    column_name: @escaping @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?,
    create_function_v2: @escaping @convention(c) (
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

extension SQLiteLibrary {
  /// The destructor that tells SQLite to copy a bound value rather than borrow it.
  ///
  /// SQLite spells this as the value `-1` cast to a destructor, which is not something a C header
  /// import can express as a constant.
  public static let transientDestructor = unsafeBitCast(-1, to: SQLiteDestructor.self)
}
