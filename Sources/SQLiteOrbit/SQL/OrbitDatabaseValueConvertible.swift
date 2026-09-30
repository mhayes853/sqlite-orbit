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
    var description = "Expected \(typeName), found \(value.orbitStorageClassName)"
    if value != .null {
      description += " \(value.debugDescription)"
    }
    if let reason {
      description += ": \(reason)"
    }
    return description
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

// MARK: - Raw representable

extension ConvertibleToOrbitDatabaseValue
where Self: RawRepresentable, RawValue: ConvertibleToOrbitDatabaseValue {
  /// The value stored for this one's raw value.
  ///
  /// ```swift
  /// enum Priority: Int, OrbitDatabaseValueConvertible {
  ///   case low, medium, high
  /// }
  ///
  /// let value = try Priority.high.orbitDatabaseValue()
  /// // .integer(2)
  /// ```
  ///
  /// - Returns: The raw value's stored value.
  /// - Throws: Whatever converting the raw value throws.
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
  /// - Parameter value: The stored raw value.
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

// MARK: - Database values

extension OrbitDatabaseValue: OrbitDatabaseValueConvertible {
  /// The value itself.
  ///
  /// ```swift
  /// let value = OrbitDatabaseValue.text("Get milk").orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: This value.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    self
  }

  /// Creates a copy of a stored value, in whatever storage class it is in.
  ///
  /// ```swift
  /// let value = try row[0, as: OrbitDatabaseValue.self]
  /// ```
  ///
  /// - Parameter value: The stored value.
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
  /// let dueDate: Int? = nil
  /// let value = try dueDate.orbitDatabaseValue()
  /// // .null
  /// ```
  ///
  /// - Returns: The stored value.
  /// - Throws: Whatever converting the wrapped value throws.
  public func orbitDatabaseValue() throws -> OrbitDatabaseValue {
    guard let self else { return .null }
    return try self.orbitDatabaseValue()
  }
}

extension Optional: ConvertibleFromOrbitDatabaseValue
where Wrapped: ConvertibleFromOrbitDatabaseValue {
  /// Creates `nil` from `NULL`, or the wrapped value from anything else.
  ///
  /// ```swift
  /// let dueDate = try row[column: "due_date", as: Int?.self]
  /// ```
  ///
  /// - Parameter value: The stored value.
  /// - Throws: Whatever reading the wrapped value throws.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard value != .null else {
      self = nil
      return
    }
    self = try Wrapped(orbitDatabaseValue: value)
  }
}
