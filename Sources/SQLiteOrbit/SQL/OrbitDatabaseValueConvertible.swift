#if Foundation
  public import _SQLiteOrbitFoundation
#endif

/// A type that can be stored as an ``OrbitDatabaseValue``.
///
/// Conforming a type is what lets it be interpolated into ``SQL``, where it is bound as a
/// parameter. The standard library's integers, floating point numbers, `Bool`, `String`, and
/// `[UInt8]` already conform, as do `Date`, `UUID`, and `Data` with the `Foundation` trait.
///
/// ```swift
/// struct Money: ConvertibleToOrbitDatabaseValue {
///   var cents: Int
///
///   func orbitDatabaseValue() -> OrbitDatabaseValue {
///     .integer(Int64(cents))
///   }
/// }
///
/// let query: SQL = "UPDATE accounts SET balance = \(Money(cents: 1_250)) WHERE id = \(id)"
/// ```
public protocol ConvertibleToOrbitDatabaseValue {
  /// The value to store for this one.
  ///
  /// ```swift
  /// let value = try 42.orbitDatabaseValue()
  /// // .integer(42)
  /// ```
  ///
  /// - Returns: The value in one of SQLite's storage classes.
  /// - Throws: When this cannot be stored, such as an unsigned integer too large for SQLite's
  ///   signed 64-bit integers. When the value is interpolated into ``SQL``, the error is thrown
  ///   by whatever runs the statement.
  func orbitDatabaseValue() throws -> OrbitDatabaseValue
}

/// A type that can be read from an ``OrbitDatabaseValue``.
///
/// Conforming a type is what lets it be read from a row with
/// ``OrbitDatabaseRow/subscript(_:as:)`` or fetched with
/// ``OrbitDatabaseReadTransaction/fetchAll(_:as:)``. Conversions are strict about the storage
/// class they read, so a column holding text never quietly reads as a number.
///
/// ```swift
/// struct Money: ConvertibleFromOrbitDatabaseValue {
///   var cents: Int
///
///   init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
///     cents = try Int(orbitDatabaseValue: value)
///   }
/// }
///
/// let balance = try row[0, as: Money.self]
/// ```
public protocol ConvertibleFromOrbitDatabaseValue {
  /// Creates a value from a stored one.
  ///
  /// ```swift
  /// let id = try Int(orbitDatabaseValue: .integer(42))
  /// ```
  ///
  /// - Parameter orbitDatabaseValue: The stored value.
  /// - Throws: ``OrbitDatabaseValueConversionError`` when the value is in a storage class, or
  ///   holds contents, that cannot produce this type.
  init(orbitDatabaseValue: OrbitDatabaseValue) throws
}

/// A type that can be both stored as and read from an ``OrbitDatabaseValue``.
///
/// An enum whose raw value converts needs no body of its own.
///
/// ```swift
/// enum Priority: Int, OrbitDatabaseValueConvertible {
///   case low, medium, high
/// }
///
/// try transaction.execute("UPDATE reminders SET priority = \(Priority.high) WHERE id = \(id)")
/// let priority = try row[column: "priority", as: Priority.self]
/// ```
public typealias OrbitDatabaseValueConvertible =
  ConvertibleToOrbitDatabaseValue & ConvertibleFromOrbitDatabaseValue

/// Reported when a stored value cannot produce the type it is read as.
///
/// The value may be in the wrong storage class, be `NULL` where the type is not optional, or hold
/// contents the type cannot be made from, such as text that does not spell a UUID.
///
/// ```swift
/// do {
///   _ = try Int(orbitDatabaseValue: .text("abc"))
/// } catch let error as OrbitDatabaseValueConversionError {
///   print(error)
///   // Expected Int, found TEXT 'abc'
/// }
/// ```
public struct OrbitDatabaseValueConversionError: Error, Hashable, CustomStringConvertible {
  /// The value that could not be converted.
  public let value: OrbitDatabaseValue

  /// The name of the type the value was being converted to.
  public let typeName: String

  /// Why the value could not produce the type, when its storage class alone does not say.
  public let reason: String?

  /// Creates an error for a value that cannot produce a type.
  ///
  /// ```swift
  /// guard case .text(let text) = value else {
  ///   throw OrbitDatabaseValueConversionError(value: value, type: Color.self)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - value: The value that could not be converted.
  ///   - type: The type it was being converted to.
  ///   - reason: Why it could not, when its storage class alone does not say.
  public init(value: OrbitDatabaseValue, type: Any.Type, reason: String? = nil) {
    self.value = value
    self.typeName = String(describing: type)
    self.reason = reason
  }

  /// The type that was expected and the value that was found, such as
  /// `Expected Int, found TEXT 'abc'`.
  public var description: String {
    let found =
      value == .null ? "NULL" : "\(value.orbitStorageClassName) \(value.debugDescription)"
    return "Expected \(typeName), found \(found)" + (reason.map { ": \($0)" } ?? "")
  }
}

extension OrbitDatabaseValue {
  // The name SQLite gives the value's storage class, as its `typeof` function spells it.
  var orbitStorageClassName: String {
    switch self {
    case .null: "NULL"
    case .integer: "INTEGER"
    case .real: "REAL"
    case .text: "TEXT"
    case .blob: "BLOB"
    }
  }
}

// Reading is as strict about storage classes as decoding a Structured Queries value, so a column
// reads the same way whichever API reads it: an integer is never widened to a real, and text is
// never parsed as a number.

// MARK: - Raw representable

extension ConvertibleToOrbitDatabaseValue
where Self: RawRepresentable, RawValue: ConvertibleToOrbitDatabaseValue {
  /// The value stored for this one's raw value.
  ///
  /// ```swift
  /// let value = try Priority.high.orbitDatabaseValue()
  /// // .integer(2)
  /// ```
  public func orbitDatabaseValue() throws -> OrbitDatabaseValue {
    try rawValue.orbitDatabaseValue()
  }
}

extension ConvertibleFromOrbitDatabaseValue
where Self: RawRepresentable, RawValue: ConvertibleFromOrbitDatabaseValue {
  /// Creates the value whose raw value is stored.
  ///
  /// ```swift
  /// let priority = try Priority(orbitDatabaseValue: .integer(2))
  /// // .high
  /// ```
  ///
  /// - Throws: Whatever reading the raw value throws, or ``OrbitDatabaseValueConversionError``
  ///   when no value has that raw value.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard let converted = Self(rawValue: try RawValue(orbitDatabaseValue: value)) else {
      throw OrbitDatabaseValueConversionError(
        value: value,
        type: Self.self,
        reason: "no value has this raw value"
      )
    }
    self = converted
  }
}

// MARK: - Integers

extension ConvertibleToOrbitDatabaseValue where Self: FixedWidthInteger {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = try UInt8(7).orbitDatabaseValue()
  /// // .integer(7)
  /// ```
  ///
  /// - Throws: An overflow error for an unsigned integer larger than `Int64.max`, which SQLite's
  ///   signed integers cannot hold.
  public func orbitDatabaseValue() throws -> OrbitDatabaseValue {
    guard let integer = Int64(exactly: self) else {
      // Structured Queries reports an unsigned integer past `Int64.max` the same way.
      throw OrbitDatabaseIntegerOverflowError(value: UInt64(clamping: self))
    }
    return .integer(integer)
  }
}

extension ConvertibleFromOrbitDatabaseValue where Self: FixedWidthInteger {
  /// Reads an integer.
  ///
  /// ```swift
  /// let level = try Int8(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer does not fit, as a negative one never does in an unsigned type.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .integer(let integer) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
    }
    guard let exact = Self(exactly: integer) else {
      throw OrbitDatabaseIntegerOverflowError(value: integer)
    }
    self = exact
  }
}

extension Int: OrbitDatabaseValueConvertible {}
extension Int8: OrbitDatabaseValueConvertible {}
extension Int16: OrbitDatabaseValueConvertible {}
extension Int32: OrbitDatabaseValueConvertible {}
extension Int64: OrbitDatabaseValueConvertible {}
extension UInt: OrbitDatabaseValueConvertible {}
extension UInt8: OrbitDatabaseValueConvertible {}
extension UInt16: OrbitDatabaseValueConvertible {}
extension UInt32: OrbitDatabaseValueConvertible {}
extension UInt64: OrbitDatabaseValueConvertible {}

// MARK: - Floating point numbers

extension ConvertibleToOrbitDatabaseValue where Self: BinaryFloatingPoint {
  /// The number as an ``OrbitDatabaseValue/real(_:)``.
  ///
  /// ```swift
  /// let value = 1.5.orbitDatabaseValue()
  /// ```
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .real(Double(self))
  }
}

extension ConvertibleFromOrbitDatabaseValue where Self: BinaryFloatingPoint {
  /// Reads a real number.
  ///
  /// An integer is not widened, so read a column that mixes the two through
  /// ``OrbitDatabaseValue/realValue``.
  ///
  /// ```swift
  /// let average = try Double(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .real(let real) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
    }
    self.init(real)
  }
}

extension Double: OrbitDatabaseValueConvertible {}
extension Float: OrbitDatabaseValueConvertible {}

// MARK: - Other values

extension Bool: OrbitDatabaseValueConvertible {
  /// The Boolean as the integer `1` or `0`, which is how SQLite spells one.
  ///
  /// ```swift
  /// let value = true.orbitDatabaseValue()
  /// // .integer(1)
  /// ```
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(self ? 1 : 0)
  }

  /// Reads an integer as a Boolean: `false` for `0`, and `true` for anything else.
  ///
  /// ```swift
  /// let isCompleted = try Bool(orbitDatabaseValue: row[0])
  /// ```
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .integer(let integer) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: Bool.self)
    }
    self = integer != 0
  }
}

extension String: OrbitDatabaseValueConvertible {
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .text(self)
  }

  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .text(let text) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: String.self)
    }
    self = text
  }
}

extension [UInt8]: OrbitDatabaseValueConvertible {
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .blob(self)
  }

  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .blob(let bytes) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: [UInt8].self)
    }
    self = bytes
  }
}

extension OrbitDatabaseValue: OrbitDatabaseValueConvertible {
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    self
  }

  public init(orbitDatabaseValue value: OrbitDatabaseValue) {
    self = value
  }
}

// MARK: - Optionals

extension Optional: ConvertibleToOrbitDatabaseValue
where Wrapped: ConvertibleToOrbitDatabaseValue {
  /// The wrapped value's stored value, or `NULL` when there is none.
  ///
  /// ```swift
  /// let value = try Int?.none.orbitDatabaseValue()
  /// // .null
  /// ```
  public func orbitDatabaseValue() throws -> OrbitDatabaseValue {
    try self?.orbitDatabaseValue() ?? .null
  }
}

extension Optional: ConvertibleFromOrbitDatabaseValue
where Wrapped: ConvertibleFromOrbitDatabaseValue {
  /// Creates `nil` from `NULL`, or the wrapped value from anything else.
  ///
  /// ```swift
  /// let dueDate = try row[column: "due_date", as: Int?.self]
  /// ```
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value == .null ? nil : Wrapped(orbitDatabaseValue: value)
  }
}

// MARK: - Foundation

#if Foundation
  extension Date: OrbitDatabaseValueConvertible {
    /// The date as ISO 8601 text, as ``OrbitDatabaseValue/init(_:)-(Date)`` spells it.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE due_date < \(Date())"
    /// ```
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      OrbitDatabaseValue(self)
    }

    /// Reads text spelling an ISO 8601 timestamp.
    ///
    /// ```swift
    /// let dueDate = try Date(orbitDatabaseValue: row[0])
    /// ```
    ///
    /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or for text
    ///   that does not spell a timestamp.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .text(let text) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Date.self)
      }
      guard let date = try? Date(orbitISO8601String: text) else {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: Date.self,
          reason: "the text is not an ISO 8601 timestamp"
        )
      }
      self = date
    }
  }

  extension UUID: OrbitDatabaseValueConvertible {
    /// The identifier as lowercase text, as ``OrbitDatabaseValue/init(_:)-(UUID)`` spells it.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE id = \(id)"
    /// ```
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      OrbitDatabaseValue(self)
    }

    /// Reads text spelling a UUID, in either case.
    ///
    /// ```swift
    /// let id = try UUID(orbitDatabaseValue: row[0])
    /// ```
    ///
    /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or for text
    ///   that does not spell a UUID.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .text(let text) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: UUID.self)
      }
      guard let uuid = UUID(uuidString: text) else {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: UUID.self,
          reason: "the text is not a UUID"
        )
      }
      self = uuid
    }
  }

  extension Data: OrbitDatabaseValueConvertible {
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      OrbitDatabaseValue(self)
    }

    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .blob(let bytes) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Data.self)
      }
      self = Data(bytes)
    }
  }
#endif
