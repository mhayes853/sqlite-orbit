#if SystemSQLite
  import CSQLite3
#elseif SQLCipher
  import SQLCipher
#elseif Turso
  import TursoSQLite3
#endif

/// The destructor SQLite calls to release a value or context it was handed.
///
/// ```swift
/// _ = sqlite3_bind_text(statement, 1, bytes, count, SQLiteLibrary.transientDestructor)
/// ```
public typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// The comparator SQLite calls to order two values under a collating sequence.
///
/// It receives the pointer the collation was registered with, then each side as a length and a
/// buffer, and returns the usual negative, zero, or positive ordering.
public typealias SQLiteComparator =
  @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafeRawPointer?
  ) -> Int32

/// The callback SQLite invokes while authorizing statement compilation.
public typealias SQLiteAuthorizerCallback =
  @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
  ) -> Int32

/// Reported when an operation is not implemented by the selected SQLite library.
public struct SQLiteFeatureUnavailableError: Error, Hashable, Sendable {
  /// The name of the library that cannot provide the operation.
  public let libraryName: String

  /// A description of the unavailable operation.
  public let feature: String

  /// Creates an error for an operation the selected library cannot provide.
  public init(libraryName: String, feature: String) {
    self.libraryName = libraryName
    self.feature = feature
  }
}

extension SQLiteFeatureUnavailableError: CustomStringConvertible {
  public var description: String {
    "\(libraryName) does not support SQLite's \(feature)."
  }
}

/// A table of the SQLite entry points SQLiteOrbit needs, grouped by responsibility.
///
/// The required groups form SQLiteOrbit's minimum SQLite-compatible contract. Optional groups are
/// `nil` when a build cannot faithfully implement their behavior. Use ``sqliteLibrary(module:apis:)``
/// to build a table from the symbols exported by a Swift module.
public struct SQLiteLibrary: Sendable {
  /// A diagnostic name for this build of SQLite.
  public var name: String
  /// Information about the loaded SQLite runtime.
  public var runtime: Runtime
  /// Operations on database connections.
  public var connection: Connection
  /// Operations on prepared statements.
  public var statement: Statement
  /// Operations that bind values to statement parameters.
  public var binding: Binding
  /// Operations that read values from result columns.
  public var column: Column
  /// Statement-compilation authorization, when the library implements it faithfully.
  public var authorization: Authorization?
  /// Custom SQL function support, when the library implements it faithfully.
  public var functions: Functions?
  /// Custom collation support, when the library implements it faithfully.
  public var collation: Collation?
  /// Database encryption support, when the library has a codec.
  public var encryption: Encryption?
  /// How database files opened by this library may be shared.
  public var fileSharing: FileSharing

  /// Creates a library from its required and optional operation groups.
  public init(
    runtime: Runtime,
    connection: Connection,
    statement: Statement,
    binding: Binding,
    column: Column,
    authorization: Authorization? = nil,
    functions: Functions? = nil,
    collation: Collation? = nil,
    encryption: Encryption? = nil,
    name: String = "custom SQLite",
    fileSharing: FileSharing = .multipleProcesses
  ) {
    self.name = name
    self.runtime = runtime
    self.connection = connection
    self.statement = statement
    self.binding = binding
    self.column = column
    self.authorization = authorization
    self.functions = functions
    self.collation = collation
    self.encryption = encryption
    self.fileSharing = fileSharing
  }
}

extension SQLiteLibrary {
  /// SQLite's `SQLITE_TRANSIENT`: the destructor that tells SQLite to copy temporary bytes.
  public static let transientDestructor = unsafeBitCast(-1, to: SQLiteDestructor.self)

  /// APIs that ``sqliteLibrary(module:apis:)`` can bind when a build provides them.
  ///
  /// This option set is consumed by the macro and is not retained as runtime capability state.
  public struct APIs: OptionSet, Hashable, Sendable {
    /// The bits representing the optional APIs to bind.
    public let rawValue: UInt8

    /// Creates a set from its raw bits.
    public init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    /// Trusted-schema control implemented with setup SQL.
    public static let trustedSchema = Self(rawValue: 1 << 0)
    /// Statement authorization through `sqlite3_set_authorizer`.
    public static let authorization = Self(rawValue: 1 << 1)
    /// Scalar SQL function registration and callbacks.
    public static let scalarFunctions = Self(rawValue: 1 << 2)
    /// Aggregate SQL function registration and callbacks.
    public static let aggregateFunctions = Self(rawValue: 1 << 3)
    /// Collating-sequence registration.
    public static let collations = Self(rawValue: 1 << 4)
    /// Codec entry points supplied by SQLCipher-compatible builds.
    public static let encryption = Self(rawValue: 1 << 5)

    /// The optional APIs provided by an ordinary SQLite build.
    public static let standard: Self = [
      .trustedSchema,
      .authorization,
      .scalarFunctions,
      .aggregateFunctions,
      .collations
    ]
    /// Every optional API known to this version of SQLiteOrbit.
    public static let all: Self = [.standard, .encryption]
  }

  /// How database files opened by the library can be shared.
  @nonexhaustive
  public enum FileSharing: Hashable, Sendable {
    /// A database file may only be opened by connections in this process.
    case singleProcess
    /// A database file may be opened and coordinated across processes.
    case multipleProcesses
  }

  /// Information about the loaded SQLite runtime.
  public struct Runtime: Sendable {
    /// The threading mode SQLite was compiled with: `sqlite3_threadsafe`.
    public var threadsafe: @Sendable () -> Int32
    /// The library's version as a number: `sqlite3_libversion_number`.
    public var versionNumber: @Sendable () -> Int32

    /// Creates a runtime operation group.
    public init(
      threadsafe: @escaping @Sendable () -> Int32,
      versionNumber: @escaping @Sendable () -> Int32
    ) {
      self.threadsafe = threadsafe
      self.versionNumber = versionNumber
    }
  }

  /// Operations on database connections.
  public struct Connection: Sendable {
    /// Opens a connection: `sqlite3_open_v2`.
    public var open:
      @Sendable (
        UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
      ) -> Int32
    /// Closes a connection once its statements are finalized: `sqlite3_close_v2`.
    public var close: @Sendable (OpaquePointer?) -> Int32
    /// The connection's current error message: `sqlite3_errmsg`.
    public var errorMessage: @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?
    /// The connection's current extended result code: `sqlite3_extended_errcode`.
    public var extendedErrorCode: @Sendable (OpaquePointer?) -> Int32
    /// Turns extended result codes on or off: `sqlite3_extended_result_codes`.
    public var setExtendedResultCodes: @Sendable (OpaquePointer?, Int32) -> Int32
    /// Sets how long a locked connection waits: `sqlite3_busy_timeout`.
    public var setBusyTimeout: @Sendable (OpaquePointer?, Int32) -> Int32
    /// Interrupts the query running on a connection: `sqlite3_interrupt`.
    public var interrupt: @Sendable (OpaquePointer?) -> Void
    /// Rows changed by the most recent statement: `sqlite3_changes`.
    public var changes: @Sendable (OpaquePointer?) -> Int32
    /// The rowid of the most recent successful insert: `sqlite3_last_insert_rowid`.
    public var lastInsertedRowID: @Sendable (OpaquePointer?) -> Int64
    /// Whether the connection currently has no transaction open: `sqlite3_get_autocommit`.
    public var isAutocommit: @Sendable (OpaquePointer?) -> Int32
    /// Applies trusted-schema behavior, or `nil` when the library cannot control it.
    public var trustedSchema: TrustedSchemaControl?

    /// Creates a connection operation group.
    public init(
      open:
        @escaping @Sendable (
          UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32,
          UnsafePointer<CChar>?
        ) -> Int32,
      close: @escaping @Sendable (OpaquePointer?) -> Int32,
      errorMessage: @escaping @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?,
      extendedErrorCode: @escaping @Sendable (OpaquePointer?) -> Int32,
      setExtendedResultCodes: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
      setBusyTimeout: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
      interrupt: @escaping @Sendable (OpaquePointer?) -> Void,
      changes: @escaping @Sendable (OpaquePointer?) -> Int32,
      lastInsertedRowID: @escaping @Sendable (OpaquePointer?) -> Int64,
      isAutocommit: @escaping @Sendable (OpaquePointer?) -> Int32,
      trustedSchema: TrustedSchemaControl?
    ) {
      self.open = open
      self.close = close
      self.errorMessage = errorMessage
      self.extendedErrorCode = extendedErrorCode
      self.setExtendedResultCodes = setExtendedResultCodes
      self.setBusyTimeout = setBusyTimeout
      self.interrupt = interrupt
      self.changes = changes
      self.lastInsertedRowID = lastInsertedRowID
      self.isAutocommit = isAutocommit
      self.trustedSchema = trustedSchema
    }
  }

  /// A library-defined operation that enables or disables trusted-schema behavior.
  public struct TrustedSchemaControl: Sendable {
    private let apply: @Sendable (borrowing SQLiteConnectionContext, Bool) throws -> Void

    /// Creates a control from an operation that borrows the connection being configured.
    public init(
      _ apply: @escaping @Sendable (borrowing SQLiteConnectionContext, Bool) throws -> Void
    ) {
      self.apply = apply
    }

    /// Applies the requested trusted-schema behavior.
    public func callAsFunction(
      _ connection: borrowing SQLiteConnectionContext,
      enabled: Bool
    ) throws {
      try apply(connection, enabled)
    }
  }

  /// Operations on prepared statements.
  public struct Statement: Sendable {
    /// Compiles one statement and reports where it stopped: `sqlite3_prepare_v3`.
    public var prepare:
      @Sendable (
        OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
        UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
      ) -> Int32
    /// Advances a statement to its next row or completion: `sqlite3_step`.
    public var step: @Sendable (OpaquePointer?) -> Int32
    /// Rewinds a statement while retaining its bindings: `sqlite3_reset`.
    public var reset: @Sendable (OpaquePointer?) -> Int32
    /// Destroys a statement: `sqlite3_finalize`.
    public var finalize: @Sendable (OpaquePointer?) -> Int32
    /// Clears a statement's parameter bindings: `sqlite3_clear_bindings`.
    public var clearBindings: @Sendable (OpaquePointer?) -> Int32
    /// Whether a statement only reads: `sqlite3_stmt_readonly`.
    public var isReadOnly: @Sendable (OpaquePointer?) -> Int32
    /// The SQL a statement was prepared from: `sqlite3_sql`.
    public var sql: @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?

    /// Creates a statement operation group.
    public init(
      prepare:
        @escaping @Sendable (
          OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
          UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
        ) -> Int32,
      step: @escaping @Sendable (OpaquePointer?) -> Int32,
      reset: @escaping @Sendable (OpaquePointer?) -> Int32,
      finalize: @escaping @Sendable (OpaquePointer?) -> Int32,
      clearBindings: @escaping @Sendable (OpaquePointer?) -> Int32,
      isReadOnly: @escaping @Sendable (OpaquePointer?) -> Int32,
      sql: @escaping @Sendable (OpaquePointer?) -> UnsafePointer<CChar>?
    ) {
      self.prepare = prepare
      self.step = step
      self.reset = reset
      self.finalize = finalize
      self.clearBindings = clearBindings
      self.isReadOnly = isReadOnly
      self.sql = sql
    }
  }

  /// Operations that bind Swift values to statement parameters.
  public struct Binding: Sendable {
    /// How many parameters a statement has: `sqlite3_bind_parameter_count`.
    public var parameterCount: @Sendable (OpaquePointer?) -> Int32
    /// Binds SQL NULL: `sqlite3_bind_null`.
    public var null: @Sendable (OpaquePointer?, Int32) -> Int32
    /// Binds a 64-bit integer: `sqlite3_bind_int64`.
    public var int64: @Sendable (OpaquePointer?, Int32, Int64) -> Int32
    /// Binds a floating-point value: `sqlite3_bind_double`.
    public var double: @Sendable (OpaquePointer?, Int32, Double) -> Int32
    /// Binds a copy of UTF-8 text: `sqlite3_bind_text` with ``transientDestructor``.
    public var text: @Sendable (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32) -> Int32
    /// Binds a copy of bytes: `sqlite3_bind_blob` with ``transientDestructor``.
    public var blob: @Sendable (OpaquePointer?, Int32, UnsafeRawPointer?, Int32) -> Int32

    /// Creates a binding operation group.
    public init(
      parameterCount: @escaping @Sendable (OpaquePointer?) -> Int32,
      null: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
      int64: @escaping @Sendable (OpaquePointer?, Int32, Int64) -> Int32,
      double: @escaping @Sendable (OpaquePointer?, Int32, Double) -> Int32,
      text: @escaping @Sendable (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32) -> Int32,
      blob: @escaping @Sendable (OpaquePointer?, Int32, UnsafeRawPointer?, Int32) -> Int32
    ) {
      self.parameterCount = parameterCount
      self.null = null
      self.int64 = int64
      self.double = double
      self.text = text
      self.blob = blob
    }
  }

  /// Operations that read values from a result row.
  public struct Column: Sendable {
    /// How many columns a result row has: `sqlite3_column_count`.
    public var count: @Sendable (OpaquePointer?) -> Int32
    /// A column's storage class: `sqlite3_column_type`.
    public var type: @Sendable (OpaquePointer?, Int32) -> Int32
    /// Reads a column as a 64-bit integer: `sqlite3_column_int64`.
    public var int64: @Sendable (OpaquePointer?, Int32) -> Int64
    /// Reads a column as a floating-point value: `sqlite3_column_double`.
    public var double: @Sendable (OpaquePointer?, Int32) -> Double
    /// Reads a column as UTF-8 text: `sqlite3_column_text`.
    public var text: @Sendable (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
    /// Reads a column as bytes: `sqlite3_column_blob`.
    public var blob: @Sendable (OpaquePointer?, Int32) -> UnsafeRawPointer?
    /// The byte count of the text or blob just read: `sqlite3_column_bytes`.
    public var byteCount: @Sendable (OpaquePointer?, Int32) -> Int32
    /// A column's name: `sqlite3_column_name`.
    public var name: @Sendable (OpaquePointer?, Int32) -> UnsafePointer<CChar>?

    /// Creates a column-reading operation group.
    public init(
      count: @escaping @Sendable (OpaquePointer?) -> Int32,
      type: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
      int64: @escaping @Sendable (OpaquePointer?, Int32) -> Int64,
      double: @escaping @Sendable (OpaquePointer?, Int32) -> Double,
      text: @escaping @Sendable (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?,
      blob: @escaping @Sendable (OpaquePointer?, Int32) -> UnsafeRawPointer?,
      byteCount: @escaping @Sendable (OpaquePointer?, Int32) -> Int32,
      name: @escaping @Sendable (OpaquePointer?, Int32) -> UnsafePointer<CChar>?
    ) {
      self.count = count
      self.type = type
      self.int64 = int64
      self.double = double
      self.text = text
      self.blob = blob
      self.byteCount = byteCount
      self.name = name
    }
  }

  /// Statement-compilation authorization operations.
  public struct Authorization: Sendable {
    /// Installs the callback invoked while statements are compiled: `sqlite3_set_authorizer`.
    public var install:
      @Sendable (OpaquePointer?, SQLiteAuthorizerCallback?, UnsafeMutableRawPointer?) -> Int32

    /// Creates an authorization operation group.
    public init(
      install:
        @escaping @Sendable (
          OpaquePointer?, SQLiteAuthorizerCallback?, UnsafeMutableRawPointer?
        ) -> Int32
    ) {
      self.install = install
    }
  }

  /// Operations used to register and run custom SQL functions.
  public struct Functions: Sendable {
    /// Function-registration operations.
    public var registration: Registration
    /// Operations that inspect a running function's context.
    public var context: Context
    /// Operations that read function arguments.
    public var argument: Argument
    /// Operations that return function results.
    public var result: Result

    /// Creates a custom-function operation group.
    public init(
      registration: Registration,
      context: Context,
      argument: Argument,
      result: Result
    ) {
      self.registration = registration
      self.context = context
      self.argument = argument
      self.result = result
    }

    /// Operations that register scalar and aggregate SQL functions.
    public struct Registration: Sendable {
      /// The shape of SQLite's `sqlite3_create_function_v2` entry point.
      public typealias Create =
        @Sendable (
          OpaquePointer?, UnsafePointer<CChar>?, Int32, Int32, UnsafeMutableRawPointer?,
          (@convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void)?,
          (@convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void)?,
          (@convention(c) (OpaquePointer?) -> Void)?, SQLiteDestructor?
        ) -> Int32

      /// Registers a scalar function, or `nil` when scalar functions are unavailable.
      public var scalar: Create?
      /// Registers an aggregate function, or `nil` when aggregate functions are unavailable.
      public var aggregate: Create?

      /// Creates a function-registration operation group.
      public init(scalar: Create?, aggregate: Create?) {
        self.scalar = scalar
        self.aggregate = aggregate
      }
    }

    /// Operations that inspect the context passed to a custom function callback.
    public struct Context: Sendable {
      /// The pointer the function was registered with: `sqlite3_user_data`.
      public var userData: @Sendable (OpaquePointer?) -> UnsafeMutableRawPointer?
      /// An aggregate's per-invocation state: `sqlite3_aggregate_context`.
      public var aggregate: (@Sendable (OpaquePointer?, Int32) -> UnsafeMutableRawPointer?)?

      /// Creates a function-context operation group.
      public init(
        userData: @escaping @Sendable (OpaquePointer?) -> UnsafeMutableRawPointer?,
        aggregate: (@Sendable (OpaquePointer?, Int32) -> UnsafeMutableRawPointer?)?
      ) {
        self.userData = userData
        self.aggregate = aggregate
      }
    }

    /// Operations that read an argument passed to a custom function.
    public struct Argument: Sendable {
      /// An argument's storage class: `sqlite3_value_type`.
      public var type: @Sendable (OpaquePointer?) -> Int32
      /// Reads an argument as a 64-bit integer: `sqlite3_value_int64`.
      public var int64: @Sendable (OpaquePointer?) -> Int64
      /// Reads an argument as a floating-point value: `sqlite3_value_double`.
      public var double: @Sendable (OpaquePointer?) -> Double
      /// Reads an argument as UTF-8 text: `sqlite3_value_text`.
      public var text: @Sendable (OpaquePointer?) -> UnsafePointer<UInt8>?
      /// Reads an argument as bytes: `sqlite3_value_blob`.
      public var blob: @Sendable (OpaquePointer?) -> UnsafeRawPointer?
      /// The byte count of the text or blob just read: `sqlite3_value_bytes`.
      public var byteCount: @Sendable (OpaquePointer?) -> Int32

      /// Creates a function-argument operation group.
      public init(
        type: @escaping @Sendable (OpaquePointer?) -> Int32,
        int64: @escaping @Sendable (OpaquePointer?) -> Int64,
        double: @escaping @Sendable (OpaquePointer?) -> Double,
        text: @escaping @Sendable (OpaquePointer?) -> UnsafePointer<UInt8>?,
        blob: @escaping @Sendable (OpaquePointer?) -> UnsafeRawPointer?,
        byteCount: @escaping @Sendable (OpaquePointer?) -> Int32
      ) {
        self.type = type
        self.int64 = int64
        self.double = double
        self.text = text
        self.blob = blob
        self.byteCount = byteCount
      }
    }

    /// Operations that return a value or error from a custom function.
    public struct Result: Sendable {
      /// Returns SQL NULL: `sqlite3_result_null`.
      public var null: @Sendable (OpaquePointer?) -> Void
      /// Returns a 64-bit integer: `sqlite3_result_int64`.
      public var int64: @Sendable (OpaquePointer?, Int64) -> Void
      /// Returns a floating-point value: `sqlite3_result_double`.
      public var double: @Sendable (OpaquePointer?, Double) -> Void
      /// Returns a copy of UTF-8 text: `sqlite3_result_text` with ``transientDestructor``.
      public var text: @Sendable (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Void
      /// Returns a copy of bytes: `sqlite3_result_blob` with ``transientDestructor``.
      public var blob: @Sendable (OpaquePointer?, UnsafeRawPointer?, Int32) -> Void
      /// Fails the function with a message: `sqlite3_result_error`.
      public var error: @Sendable (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Void

      /// Creates a function-result operation group.
      public init(
        null: @escaping @Sendable (OpaquePointer?) -> Void,
        int64: @escaping @Sendable (OpaquePointer?, Int64) -> Void,
        double: @escaping @Sendable (OpaquePointer?, Double) -> Void,
        text: @escaping @Sendable (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Void,
        blob: @escaping @Sendable (OpaquePointer?, UnsafeRawPointer?, Int32) -> Void,
        error: @escaping @Sendable (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Void
      ) {
        self.null = null
        self.int64 = int64
        self.double = double
        self.text = text
        self.blob = blob
        self.error = error
      }
    }
  }

  /// Operations that register custom collating sequences.
  public struct Collation: Sendable {
    /// Registers a collating sequence: `sqlite3_create_collation_v2`.
    public var create:
      @Sendable (
        OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?, SQLiteComparator?,
        SQLiteDestructor?
      ) -> Int32

    /// Creates a collation operation group.
    public init(
      create:
        @escaping @Sendable (
          OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?, SQLiteComparator?,
          SQLiteDestructor?
        ) -> Int32
    ) {
      self.create = create
    }
  }

  /// Codec operations supplied by SQLCipher-compatible builds.
  public struct Encryption: Sendable {
    /// Unlocks a database: `sqlite3_key_v2`.
    public var key:
      @Sendable (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) -> Int32
    /// Re-encrypts a database under a new key: `sqlite3_rekey_v2`.
    public var rekey:
      @Sendable (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) -> Int32

    /// Creates an encryption operation group.
    public init(
      key:
        @escaping @Sendable (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) ->
        Int32,
      rekey:
        @escaping @Sendable (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) ->
        Int32
    ) {
      self.key = key
      self.rekey = rekey
    }
  }
}

/// A borrowed view of a connection while SQLiteOrbit applies connection controls.
public struct SQLiteConnectionContext: ~Copyable {
  private let connection: OpaquePointer
  private let library: UnsafePointer<SQLiteLibrary>

  init(connection: OpaquePointer, library: UnsafePointer<SQLiteLibrary>) {
    self.connection = connection
    self.library = library
  }

  /// The raw connection being configured.
  ///
  /// Prefer ``execute(_:)`` when setup SQL is sufficient. This escape hatch supports library
  /// controls that require engine-specific entry points.
  public var rawConnection: OpaquePointer { connection }

  /// Executes setup SQL on the borrowed connection.
  public borrowing func execute(_ sql: String) throws {
    try SQLiteHandle.execute(sql, on: connection, library: library)
  }
}

#if BuiltInSQLite
  extension SQLiteLibrary {
    private static func configured(
      _ library: Self,
      name: String,
      fileSharing: FileSharing
    ) -> Self {
      var library = library
      library.name = name
      library.fileSharing = fileSharing
      return library
    }

    static var builtIn: Self {
      #if SystemSQLite
        .system
      #elseif SQLCipher
        .sqlCipher
      #elseif Turso
        .turso
      #endif
    }
  }
#endif

#if SystemSQLite
  extension SQLiteLibrary {
    /// The SQLite library supplied by the operating system.
    public static let system = configured(
      #sqliteLibrary(),
      name: "system SQLite",
      fileSharing: .multipleProcesses
    )
  }
#endif

#if SQLCipher
  extension SQLiteLibrary {
    /// The package's SQLCipher library, including its codec operations.
    public static let sqlCipher = configured(
      #sqliteLibrary(apis: [.standard, .encryption]),
      name: "SQLCipher",
      fileSharing: .multipleProcesses
    )
  }
#endif

#if Turso
  extension SQLiteLibrary {
    /// Turso's local SQLite-compatible Rust engine.
    public static let turso = configured(
      #sqliteLibrary(module: "TursoSQLite3", apis: []),
      name: "Turso",
      fileSharing: .singleProcess
    )
  }
#endif
