#if Foundation
  public import _SQLiteOrbitFoundation
#endif

// Reading is as strict about storage classes as decoding a Structured Queries value, so a column
// reads the same way whichever API reads it: an integer is never widened to a real, and text is
// never parsed as a number.

// MARK: - Signed integers

extension Int: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = 42.orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(self))
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let id = try Int(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer does not fit, as it may not where `Int` is 32 bits wide.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(Int.self)
  }
}

extension Int8: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = Int8(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(self))
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let level = try Int8(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer does not fit.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(Int8.self)
  }
}

extension Int16: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = Int16(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(self))
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let year = try Int16(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer does not fit.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(Int16.self)
  }
}

extension Int32: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = Int32(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(self))
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let count = try Int32(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer does not fit.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(Int32.self)
  }
}

extension Int64: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = Int64(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(self)
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let rowID = try Int64(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(Int64.self)
  }
}

// MARK: - Unsigned integers

extension UInt: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = try UInt(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  /// - Throws: An overflow error when the integer is larger than `Int64.max`, which SQLite's
  ///   signed integers cannot hold.
  public func orbitDatabaseValue() throws -> OrbitDatabaseValue {
    try OrbitDatabaseValue(orbitUnsigned: self)
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let count = try UInt(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer is negative or does not fit.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(UInt.self)
  }
}

extension UInt8: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = UInt8(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(self))
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let byte = try UInt8(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer is negative or does not fit.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(UInt8.self)
  }
}

extension UInt16: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = UInt16(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(self))
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let port = try UInt16(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer is negative or does not fit.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(UInt16.self)
  }
}

extension UInt32: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = UInt32(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(Int64(self))
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let color = try UInt32(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer is negative or does not fit.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(UInt32.self)
  }
}

extension UInt64: OrbitDatabaseValueConvertible {
  /// The integer as an ``OrbitDatabaseValue/integer(_:)``.
  ///
  /// ```swift
  /// let value = try UInt64(7).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored integer.
  /// - Throws: An overflow error when the integer is larger than `Int64.max`, which SQLite's
  ///   signed integers cannot hold.
  public func orbitDatabaseValue() throws -> OrbitDatabaseValue {
    try OrbitDatabaseValue(orbitUnsigned: self)
  }

  /// Reads an integer.
  ///
  /// ```swift
  /// let size = try UInt64(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or an overflow
  ///   error when the integer is negative.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    self = try value.orbitInteger(UInt64.self)
  }
}

extension OrbitDatabaseValue {
  // Reads an integer of any width. A value that does not fit throws the same overflow error as
  // decoding it through Structured Queries does.
  func orbitInteger<Integer: FixedWidthInteger>(_ type: Integer.Type) throws -> Integer {
    guard case .integer(let value) = self else {
      throw OrbitDatabaseValueConversionError(value: self, type: Integer.self)
    }
    guard let integer = Integer(exactly: value) else {
      throw OrbitDatabaseIntegerOverflowError(value: value)
    }
    return integer
  }

  // Stores an unsigned integer, which SQLite's signed integers can hold only up to `Int64.max`.
  init(orbitUnsigned value: some UnsignedInteger) throws {
    guard let integer = Int64(exactly: value) else {
      throw OrbitDatabaseIntegerOverflowError(value: UInt64(value))
    }
    self = .integer(integer)
  }
}

// MARK: - Floating point numbers

extension Double: OrbitDatabaseValueConvertible {
  /// The number as an ``OrbitDatabaseValue/real(_:)``.
  ///
  /// ```swift
  /// let value = 1.5.orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored number.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .real(self)
  }

  /// Reads a real number.
  ///
  /// An integer is not widened, so store a number that must read as a `Double` as a real, or read
  /// a mixed column through ``OrbitDatabaseValue/realValue``.
  ///
  /// ```swift
  /// let average = try Double(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be a real number.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .real(let real) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: Double.self)
    }
    self = real
  }
}

extension Float: OrbitDatabaseValueConvertible {
  /// The number as an ``OrbitDatabaseValue/real(_:)``.
  ///
  /// ```swift
  /// let value = Float(1.5).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored number.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .real(Double(self))
  }

  /// Reads a real number, rounded to the nearest `Float`.
  ///
  /// ```swift
  /// let ratio = try Float(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be a real number.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .real(let real) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: Float.self)
    }
    self = Float(real)
  }
}

// MARK: - Booleans, text, and bytes

extension Bool: OrbitDatabaseValueConvertible {
  /// The Boolean as the integer `1` or `0`, which is how SQLite spells one.
  ///
  /// ```swift
  /// let value = true.orbitDatabaseValue()
  /// // .integer(1)
  /// ```
  ///
  /// - Returns: The stored integer.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .integer(self ? 1 : 0)
  }

  /// Reads an integer as a Boolean: `false` for `0`, and `true` for anything else.
  ///
  /// ```swift
  /// let isCompleted = try Bool(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be an integer.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .integer(let integer) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: Bool.self)
    }
    self = integer != 0
  }
}

extension String: OrbitDatabaseValueConvertible {
  /// The string as ``OrbitDatabaseValue/text(_:)``.
  ///
  /// ```swift
  /// let value = "Get milk".orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored text.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .text(self)
  }

  /// Reads text.
  ///
  /// ```swift
  /// let title = try String(orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be text.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .text(let text) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: String.self)
    }
    self = text
  }
}

extension [UInt8]: OrbitDatabaseValueConvertible {
  /// The bytes as a ``OrbitDatabaseValue/blob(_:)``.
  ///
  /// ```swift
  /// let value = [UInt8]([0xde, 0xad]).orbitDatabaseValue()
  /// ```
  ///
  /// - Returns: The stored blob.
  public func orbitDatabaseValue() -> OrbitDatabaseValue {
    .blob(self)
  }

  /// Reads a blob.
  ///
  /// ```swift
  /// let thumbnail = try [UInt8](orbitDatabaseValue: row[0])
  /// ```
  ///
  /// - Parameter value: The stored value, which must be a blob.
  /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class.
  public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
    guard case .blob(let bytes) = value else {
      throw OrbitDatabaseValueConversionError(value: value, type: [UInt8].self)
    }
    self = bytes
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
    ///
    /// - Returns: The stored text.
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      OrbitDatabaseValue(self)
    }

    /// Reads text spelling an ISO 8601 timestamp.
    ///
    /// ```swift
    /// let dueDate = try Date(orbitDatabaseValue: row[0])
    /// ```
    ///
    /// - Parameter value: The stored value, which must be text spelling a timestamp.
    /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or for text
    ///   that does not spell a timestamp.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .text(let text) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Date.self)
      }
      do {
        self = try Date(orbitISO8601String: text)
      } catch {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: Date.self,
          reason: "the text is not an ISO 8601 timestamp"
        )
      }
    }
  }

  extension UUID: OrbitDatabaseValueConvertible {
    /// The identifier as lowercase text, as ``OrbitDatabaseValue/init(_:)-(UUID)`` spells it.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE id = \(id)"
    /// ```
    ///
    /// - Returns: The stored text.
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      OrbitDatabaseValue(self)
    }

    /// Reads text spelling a UUID, in either case.
    ///
    /// ```swift
    /// let id = try UUID(orbitDatabaseValue: row[0])
    /// ```
    ///
    /// - Parameter value: The stored value, which must be text spelling a UUID.
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
    /// The bytes as a ``OrbitDatabaseValue/blob(_:)``.
    ///
    /// ```swift
    /// let value = Data([0xde, 0xad]).orbitDatabaseValue()
    /// ```
    ///
    /// - Returns: The stored blob.
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      OrbitDatabaseValue(self)
    }

    /// Reads a blob.
    ///
    /// ```swift
    /// let thumbnail = try Data(orbitDatabaseValue: row[0])
    /// ```
    ///
    /// - Parameter value: The stored value, which must be a blob.
    /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .blob(let bytes) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Data.self)
      }
      self = Data(bytes)
    }
  }
#endif
