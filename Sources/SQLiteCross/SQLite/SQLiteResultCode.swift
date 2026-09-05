/// A result code returned by a SQLite entry point.
///
/// SQLite's numeric codes are part of its stable ABI, so they are declared here rather than
/// imported. That is what lets ``SQLiteCross`` talk to a SQLite build it does not link against.
/// ``systemConstantsMatchTheSQLiteHeaders()`` checks these values against the linked library.
public struct SQLiteResultCode: RawRepresentable, Hashable, Sendable {
  public let rawValue: Int32

  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  public static let ok = Self(rawValue: 0)
  public static let error = Self(rawValue: 1)
  public static let interrupt = Self(rawValue: 9)
  public static let busy = Self(rawValue: 5)
  public static let locked = Self(rawValue: 6)
  public static let readOnly = Self(rawValue: 8)
  public static let ioError = Self(rawValue: 10)
  public static let corrupt = Self(rawValue: 11)
  public static let full = Self(rawValue: 13)
  public static let cantOpen = Self(rawValue: 14)
  public static let constraint = Self(rawValue: 19)
  public static let mismatch = Self(rawValue: 20)
  public static let misuse = Self(rawValue: 21)
  public static let notADatabase = Self(rawValue: 26)
  public static let row = Self(rawValue: 100)
  public static let done = Self(rawValue: 101)

  /// The primary result code, with any extended result bits removed.
  public var primary: Self {
    Self(rawValue: rawValue & 0xff)
  }
}

/// The flags that describe how a database is opened.
public struct SQLiteOpenFlags: OptionSet, Hashable, Sendable {
  public let rawValue: Int32

  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  public static let readOnly = Self(rawValue: 0x0000_0001)
  public static let readWrite = Self(rawValue: 0x0000_0002)
  public static let create = Self(rawValue: 0x0000_0004)
  public static let uri = Self(rawValue: 0x0000_0040)
  public static let memory = Self(rawValue: 0x0000_0080)
  public static let noMutex = Self(rawValue: 0x0000_8000)
  public static let fullMutex = Self(rawValue: 0x0001_0000)
  public static let sharedCache = Self(rawValue: 0x0002_0000)
  public static let privateCache = Self(rawValue: 0x0004_0000)
}

/// The flags that describe how a statement is prepared.
public struct SQLitePrepareFlags: OptionSet, Hashable, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  /// Hints that the statement will be reused, which is what a statement cache does.
  public static let persistent = Self(rawValue: 0x01)
  public static let normalize = Self(rawValue: 0x02)
  public static let noVirtualTable = Self(rawValue: 0x04)
}

/// The datatype of a value in a result row.
public struct SQLiteColumnType: RawRepresentable, Hashable, Sendable {
  public let rawValue: Int32

  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  public static let integer = Self(rawValue: 1)
  public static let float = Self(rawValue: 2)
  public static let text = Self(rawValue: 3)
  public static let blob = Self(rawValue: 4)
  public static let null = Self(rawValue: 5)
}

/// The text encoding and behavior flags accepted when registering a custom function.
public struct SQLiteFunctionFlags: OptionSet, Hashable, Sendable {
  public let rawValue: Int32

  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  public static let utf8 = Self(rawValue: 1)
  public static let deterministic = Self(rawValue: 0x0000_0800)
  public static let directOnly = Self(rawValue: 0x0008_0000)
  public static let innocuous = Self(rawValue: 0x0020_0000)
}
