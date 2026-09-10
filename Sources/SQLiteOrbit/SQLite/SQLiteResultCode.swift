/// A result code returned by a SQLite entry point.
///
/// SQLite's numeric codes are part of its stable ABI, so they are declared here rather than
/// imported. That is what lets ``SQLiteOrbit`` talk to a SQLite build it does not link against.
/// ``systemConstantsMatchTheSQLiteHeaders()`` checks these values against the linked library.
///
/// ```swift
/// catch let error as SQLiteError where error.primaryCode == .constraint {
///   print("a constraint rejected the write")
/// }
/// ```
public struct SQLiteResultCode: RawRepresentable, Hashable, Sendable {
  /// The code SQLite returned, extended bits included.
  public let rawValue: Int32

  /// Creates a result code from the number SQLite returned.
  ///
  /// - Parameter rawValue: The code, extended bits included.
  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  /// `SQLITE_OK`: the call succeeded.
  public static let ok = Self(rawValue: 0)
  /// `SQLITE_ERROR`: a generic failure, usually a SQL error.
  public static let error = Self(rawValue: 1)
  /// `SQLITE_INTERRUPT`: the running statement was interrupted, which is how a cancelled task
  /// stops a query.
  public static let interrupt = Self(rawValue: 9)
  /// `SQLITE_BUSY`: another connection or process holds a lock this one waited too long for.
  public static let busy = Self(rawValue: 5)
  /// `SQLITE_LOCKED`: a table in the same database is locked.
  public static let locked = Self(rawValue: 6)
  /// `SQLITE_READONLY`: a write was attempted on a database that cannot be written.
  public static let readOnly = Self(rawValue: 8)
  /// `SQLITE_IOERR`: the filesystem reported a failure.
  public static let ioError = Self(rawValue: 10)
  /// `SQLITE_CORRUPT`: the database file is malformed.
  public static let corrupt = Self(rawValue: 11)
  /// `SQLITE_FULL`: the database or disk is full.
  public static let full = Self(rawValue: 13)
  /// `SQLITE_CANTOPEN`: the database file could not be opened.
  public static let cantOpen = Self(rawValue: 14)
  /// `SQLITE_CONSTRAINT`: a constraint rejected the statement.
  public static let constraint = Self(rawValue: 19)
  /// `SQLITE_MISMATCH`: a value had the wrong datatype for its column.
  public static let mismatch = Self(rawValue: 20)
  /// `SQLITE_MISUSE`: the library was used incorrectly.
  public static let misuse = Self(rawValue: 21)
  /// `SQLITE_NOTADB`: the file is not a database.
  public static let notADatabase = Self(rawValue: 26)
  /// `SQLITE_ROW`: the statement produced a row.
  public static let row = Self(rawValue: 100)
  /// `SQLITE_DONE`: the statement has no more rows.
  public static let done = Self(rawValue: 101)

  /// The primary result code, with any extended result bits removed.
  public var primary: Self {
    Self(rawValue: rawValue & 0xff)
  }

  /// Whether the code reports success rather than failure.
  ///
  /// Extended result bits are ignored, so a success SQLite qualified — `SQLITE_OK_LOAD_PERMANENTLY`
  /// and the like — is still a success.
  public var isSuccess: Bool {
    let primary = primary
    return primary == .ok || primary == .row || primary == .done
  }
}

/// The flags that describe how a database is opened.
///
/// These are the third argument to `sqlite3_open_v2`, so they matter to a caller reaching for
/// ``SQLiteLibrary/Connection/open`` directly.
///
/// ```swift
/// let flags: SQLiteOpenFlags = [.readWrite, .create, .noMutex]
/// ```
public struct SQLiteOpenFlags: OptionSet, Hashable, Sendable {
  /// The bits SQLite is handed.
  public let rawValue: Int32

  /// Creates a flag set from its bits.
  ///
  /// - Parameter rawValue: The bits SQLite is handed.
  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  /// `SQLITE_OPEN_READONLY`.
  public static let readOnly = Self(rawValue: 0x0000_0001)
  /// `SQLITE_OPEN_READWRITE`.
  public static let readWrite = Self(rawValue: 0x0000_0002)
  /// `SQLITE_OPEN_CREATE`.
  public static let create = Self(rawValue: 0x0000_0004)
  /// `SQLITE_OPEN_URI`.
  public static let uri = Self(rawValue: 0x0000_0040)
  /// `SQLITE_OPEN_MEMORY`.
  public static let memory = Self(rawValue: 0x0000_0080)
  /// `SQLITE_OPEN_NOMUTEX`.
  public static let noMutex = Self(rawValue: 0x0000_8000)
  /// `SQLITE_OPEN_FULLMUTEX`.
  public static let fullMutex = Self(rawValue: 0x0001_0000)
  /// `SQLITE_OPEN_SHAREDCACHE`.
  public static let sharedCache = Self(rawValue: 0x0002_0000)
  /// `SQLITE_OPEN_PRIVATECACHE`.
  public static let privateCache = Self(rawValue: 0x0004_0000)
}

/// The flags that describe how a statement is prepared.
///
/// These are the fourth argument to `sqlite3_prepare_v3`.
///
/// ```swift
/// _ = library.statements.preparation.prepare(connection, sql, -1, SQLitePrepareFlags.persistent.rawValue, &stmt, nil)
/// ```
public struct SQLitePrepareFlags: OptionSet, Hashable, Sendable {
  /// The bits SQLite is handed.
  public let rawValue: UInt32

  /// Creates a flag set from its bits.
  ///
  /// - Parameter rawValue: The bits SQLite is handed.
  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  /// `SQLITE_PREPARE_PERSISTENT`: hints that the statement will be reused, which is what a
  /// statement cache does.
  public static let persistent = Self(rawValue: 0x01)
  /// `SQLITE_PREPARE_NORMALIZE`, which is a no-op in current SQLite.
  public static let normalize = Self(rawValue: 0x02)
  /// `SQLITE_PREPARE_NO_VTAB`: refuses a statement that uses a virtual table.
  public static let noVirtualTable = Self(rawValue: 0x04)
}

/// The datatype of a value in a result row.
///
/// SQLite calls these storage classes, and they are what ``SQLiteLibrary/Column/type`` returns.
///
/// ```swift
/// if library.columns.type(statement, 0) == SQLiteColumnType.null.rawValue { ... }
/// ```
public struct SQLiteColumnType: RawRepresentable, Hashable, Sendable {
  /// The number SQLite reports for this storage class.
  public let rawValue: Int32

  /// Creates a storage class from the number SQLite reports.
  ///
  /// - Parameter rawValue: The number SQLite reports.
  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  /// `SQLITE_INTEGER`.
  public static let integer = Self(rawValue: 1)
  /// `SQLITE_FLOAT`.
  public static let float = Self(rawValue: 2)
  /// `SQLITE_TEXT`.
  public static let text = Self(rawValue: 3)
  /// `SQLITE_BLOB`.
  public static let blob = Self(rawValue: 4)
  /// `SQLITE_NULL`.
  public static let null = Self(rawValue: 5)
}

/// The text encoding and behavior flags accepted when registering a custom function.
///
/// These are the fourth argument to `sqlite3_create_function_v2`, so they matter to a caller
/// reaching for ``SQLiteLibrary/Functions/Registration/scalar`` directly.
///
/// ```swift
/// let flags: SQLiteFunctionFlags = [.utf8, .deterministic]
/// _ = library.scalarFunctions!.register(
///   connection, "double", 1, flags.rawValue, nil, xFunc, nil, nil, nil
/// )
/// ```
public struct SQLiteFunctionFlags: OptionSet, Hashable, Sendable {
  /// The bits SQLite is handed.
  public let rawValue: Int32

  /// Creates a flag set from its bits.
  ///
  /// - Parameter rawValue: The bits SQLite is handed.
  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  /// `SQLITE_UTF8`: arguments and results are UTF-8.
  public static let utf8 = Self(rawValue: 1)
  /// `SQLITE_DETERMINISTIC`: the same arguments always produce the same result, which lets SQLite
  /// use the function in an index.
  public static let deterministic = Self(rawValue: 0x0000_0800)
  /// `SQLITE_DIRECTONLY`: the function may only be called from top-level SQL, never from a
  /// schema-defined trigger, view, or index.
  public static let directOnly = Self(rawValue: 0x0008_0000)
  /// `SQLITE_INNOCUOUS`: the function has no side effects and reveals nothing outside the
  /// database.
  public static let innocuous = Self(rawValue: 0x0020_0000)
}
