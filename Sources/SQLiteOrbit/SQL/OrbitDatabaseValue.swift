#if Foundation
  public import _SQLiteOrbitFoundation
#endif

/// A value as SQLite stores it: one of its five storage classes.
///
/// This is what raw ``SQL`` binds to its parameters, what an ``OrbitDatabaseRow`` reads out of a
/// column, and what a function registered with
/// ``SQLiteConfiguration/registerFunction(_:argumentCount:isDeterministic:_:)`` receives and
/// returns. SQLite has no separate boolean or date types, so a `Bool` is stored as an integer and a
/// date as text, the way the `Foundation` trait's conveniences spell it.
///
/// ```swift
/// let values: [OrbitDatabaseValue] = [nil, 42, 1.5, "Get milk", .blob([0xde, 0xad])]
/// try transaction.execute(
///   "INSERT INTO notes (id, body) VALUES (\(OrbitDatabaseValue.integer(1)), \(values[3]))"
/// )
/// ```
public enum OrbitDatabaseValue: Hashable, Sendable {
  /// SQL `NULL`.
  case null

  /// A 64-bit signed integer.
  case integer(Int64)

  /// A 64-bit floating point number.
  case real(Double)

  /// UTF-8 text.
  case text(String)

  /// Raw bytes.
  case blob([UInt8])
}

extension OrbitDatabaseValue: ExpressibleByNilLiteral {
  /// Creates SQL `NULL`.
  ///
  /// ```swift
  /// let value: OrbitDatabaseValue = nil
  /// ```
  public init(nilLiteral: ()) {
    self = .null
  }
}

extension OrbitDatabaseValue: ExpressibleByIntegerLiteral {
  /// Creates an integer.
  ///
  /// ```swift
  /// let value: OrbitDatabaseValue = 42
  /// ```
  public init(integerLiteral value: Int64) {
    self = .integer(value)
  }
}

extension OrbitDatabaseValue: ExpressibleByFloatLiteral {
  /// Creates a real number.
  ///
  /// ```swift
  /// let value: OrbitDatabaseValue = 1.5
  /// ```
  public init(floatLiteral value: Double) {
    self = .real(value)
  }
}

extension OrbitDatabaseValue: ExpressibleByStringLiteral {
  /// Creates text.
  ///
  /// ```swift
  /// let value: OrbitDatabaseValue = "Get milk"
  /// ```
  public init(stringLiteral value: String) {
    self = .text(value)
  }
}

extension OrbitDatabaseValue {
  /// Whether this is SQL `NULL`.
  ///
  /// ```swift
  /// let isMissing = row[column: "due_date"]?.isNull ?? true
  /// ```
  public var isNull: Bool {
    self == .null
  }

  /// The integer this holds, or `nil` for any other storage class.
  ///
  /// ```swift
  /// let id = row[0].integerValue
  /// ```
  public var integerValue: Int64? {
    guard case .integer(let value) = self else { return nil }
    return value
  }

  /// The real number this holds, or `nil` for anything but a real or an integer.
  ///
  /// An integer is widened, so a numeric column holding a mix of the two reads as one type.
  ///
  /// ```swift
  /// let average = row[0].realValue
  /// ```
  public var realValue: Double? {
    switch self {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: nil
    }
  }

  /// The text this holds, or `nil` for any other storage class.
  ///
  /// ```swift
  /// let title = row[column: "title"]?.textValue
  /// ```
  public var textValue: String? {
    guard case .text(let value) = self else { return nil }
    return value
  }

  /// The bytes this holds, or `nil` for any other storage class.
  ///
  /// ```swift
  /// let thumbnail = row[column: "thumbnail"]?.blobValue
  /// ```
  public var blobValue: [UInt8]? {
    guard case .blob(let value) = self else { return nil }
    return value
  }
}

extension OrbitDatabaseValue: CustomDebugStringConvertible {
  /// The value spelled as a SQL literal, such as `'Get milk'` or `NULL`.
  public var debugDescription: String {
    switch self {
    case .null:
      return "NULL"
    case .integer(let value):
      return "\(value)"
    case .real(let value):
      return "\(value)"
    case .text(let value):
      return orbitQuoted(value, delimiter: "'")
    case .blob(let bytes):
      return "X'" + LowercaseHexadecimal.string(bytes) + "'"
    }
  }
}

// MARK: - Foundation

#if Foundation
  extension OrbitDatabaseValue {
    /// Creates text spelling `date` as an ISO 8601 timestamp.
    ///
    /// The timestamp is in UTC with millisecond precision, such as `2026-01-29 00:08:00.000`,
    /// which is the form SQLite's own date functions read and sort correctly as text.
    ///
    /// ```swift
    /// let value = OrbitDatabaseValue(Date())
    /// ```
    ///
    /// - Parameter date: The date to store.
    public init(_ date: Date) {
      self = .text(date.orbitISO8601String)
    }

    /// Creates text spelling `uuid` in lowercase.
    ///
    /// ```swift
    /// let value = OrbitDatabaseValue(UUID())
    /// ```
    ///
    /// - Parameter uuid: The identifier to store.
    public init(_ uuid: UUID) {
      self = .text(uuid.uuidString.lowercased())
    }

    /// Creates a blob holding `data`'s bytes.
    ///
    /// ```swift
    /// let value = OrbitDatabaseValue(Data([0xde, 0xad]))
    /// ```
    ///
    /// - Parameter data: The bytes to store.
    public init(_ data: Data) {
      self = .blob([UInt8](data))
    }

    /// The date this text spells as an ISO 8601 timestamp, or `nil` for anything else.
    ///
    /// ```swift
    /// let dueDate = row[column: "due_date"]?.dateValue
    /// ```
    public var dateValue: Date? {
      guard case .text(let text) = self else { return nil }
      return try? Date(orbitISO8601String: text)
    }

    /// The UUID this text spells, in either case, or `nil` for anything else.
    ///
    /// ```swift
    /// let id = row[column: "id"]?.uuidValue
    /// ```
    public var uuidValue: UUID? {
      guard case .text(let text) = self else { return nil }
      return UUID(uuidString: text)
    }

    /// The bytes of this blob as `Data`, or `nil` for any other storage class.
    ///
    /// ```swift
    /// let thumbnail = row[column: "thumbnail"]?.dataValue
    /// ```
    public var dataValue: Data? {
      guard case .blob(let bytes) = self else { return nil }
      return Data(bytes)
    }
  }
#endif
