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
