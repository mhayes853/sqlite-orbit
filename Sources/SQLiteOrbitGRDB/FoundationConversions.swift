#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  #if canImport(CoreGraphics)
    import CoreGraphics
  #endif

  // Foundation reference types and numeric types, stored as GRDB stores them.

  private let posixLocale = Locale(identifier: "en_US_POSIX")

  extension NSNull: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { .null }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? { nil }
  }

  extension NSString: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      #if canImport(Darwin)
        (self as String).databaseValue
      #else
        String._unconditionallyBridgeFromObjectiveC(self).databaseValue
      #endif
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      String.fromDatabaseValue(dbValue).map { Self(string: $0) }
    }
  }

  extension NSData: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      Data(referencing: self).databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      Data.fromDatabaseValue(dbValue).flatMap { NSData(data: $0) as? Self }
    }
  }

  extension NSDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate).databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      Date.fromDatabaseValue(dbValue)
        .flatMap {
          NSDate(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate) as? Self
        }
    }
  }

  extension NSURL: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      #if canImport(Darwin)
        absoluteString?.databaseValue ?? .null
      #else
        absoluteString.databaseValue
      #endif
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      String.fromDatabaseValue(dbValue).flatMap { NSURL(string: $0) as? Self }
    }
  }

  extension NSUUID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      UUID(uuidString: uuidString)!.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      switch dbValue.storage {
      case .blob(let data) where data.count != 16:
        return nil
      case .blob, .string:
        return UUID.fromDatabaseValue(dbValue)
          .flatMap { NSUUID(uuidString: $0.uuidString) as? Self }
      default:
        return nil
      }
    }
  }

  extension NSNumber: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      // Integral decimal numbers in the Int64 range are stored as integers.
      if let decimal = self as? NSDecimalNumber {
        let value = decimal.decimalValue
        var rounded = Decimal()
        var copy = value
        NSDecimalRound(&rounded, &copy, 0, .plain)
        if rounded == value, value <= Decimal(Int64.max), value >= Decimal(Int64.min) {
          return int64Value.databaseValue
        }
        return doubleValue.databaseValue
      }
      switch String(cString: objCType) {
      case "c": return Int64(int8Value).databaseValue
      case "C": return Int64(uint8Value).databaseValue
      case "s": return Int64(int16Value).databaseValue
      case "S": return Int64(uint16Value).databaseValue
      case "i": return Int64(int32Value).databaseValue
      case "I": return Int64(uint32Value).databaseValue
      case "l": return Int64(intValue).databaseValue
      case "L":
        let value = uintValue
        precondition(
          UInt64(value) <= UInt64(Int64.max),
          "could not convert \(value) to an Int64 that can be stored in the database"
        )
        return Int64(value).databaseValue
      case "q": return int64Value.databaseValue
      case "Q":
        let value = uint64Value
        precondition(
          value <= UInt64(Int64.max),
          "could not convert \(value) to an Int64 that can be stored in the database"
        )
        return Int64(value).databaseValue
      case "f": return Double(floatValue).databaseValue
      case "d": return doubleValue.databaseValue
      case "B": return boolValue.databaseValue
      case let type: fatalError("DatabaseValueConvertible: Unsupported NSNumber type: \(type)")
      }
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      let decimal = self is NSDecimalNumber.Type
      switch dbValue.storage {
      case .int64(let value):
        return (decimal ? NSDecimalNumber(value: value) : NSNumber(value: value)) as? Self
      case .double(let value):
        return (decimal ? NSDecimalNumber(value: value) : NSNumber(value: value)) as? Self
      case .string(let string):
        // Matches Decimal.fromDatabaseValue(_:).
        return Decimal(string: string, locale: posixLocale)
          .flatMap {
            NSDecimalNumber(decimal: $0) as? Self
          }
      default:
        return nil
      }
    }
  }

  extension Decimal: DatabaseValueConvertible {
    /// Decimal numbers are stored as text, which preserves their precision.
    public var databaseValue: DatabaseValue {
      NSDecimalNumber(decimal: self).description(withLocale: posixLocale).databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Decimal? {
      switch dbValue.storage {
      case .int64(let value): Decimal(value)
      case .double(let value): Decimal(value)
      case .string(let string): Decimal(string: string, locale: posixLocale)
      default: nil
      }
    }
  }

  extension CGFloat: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      Double(self).databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CGFloat? {
      Double.fromDatabaseValue(dbValue).map { CGFloat($0) }
    }
  }

  extension Row {
    /// Creates a row from a Foundation dictionary, or nil unless all keys are strings and all
    /// values are DatabaseValueConvertible.
    public convenience init?(_ dictionary: [AnyHashable: Any]) {
      var columns: [(String, DatabaseValue)] = []
      for (key, value) in dictionary {
        guard let key = key as? String, let value = DatabaseValue(value: value) else {
          return nil
        }
        columns.append((key, value))
      }
      self.init(columns)
    }
  }
#endif
