#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  public protocol DatabaseValueConvertible: SQLExpressible {
    var databaseValue: DatabaseValue { get }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self?

    /// The decoder of values stored as JSON, for Decodable types.
    static func databaseJSONDecoder() -> JSONDecoder

    /// The encoder of values stored as JSON, for Encodable types.
    static func databaseJSONEncoder() -> JSONEncoder
  }

  extension DatabaseValueConvertible {
    public static func databaseJSONDecoder() -> JSONDecoder {
      let decoder = JSONDecoder()
      decoder.dataDecodingStrategy = .base64
      decoder.dateDecodingStrategy = .millisecondsSince1970
      decoder.nonConformingFloatDecodingStrategy = .throw
      return decoder
    }

    public static func databaseJSONEncoder() -> JSONEncoder {
      let encoder = JSONEncoder()
      encoder.dataEncodingStrategy = .base64
      encoder.dateEncodingStrategy = .millisecondsSince1970
      encoder.nonConformingFloatEncodingStrategy = .throw
      encoder.outputFormatting = .sortedKeys
      return encoder
    }
  }

  extension DatabaseValueConvertible {
    public var sqlExpression: SQLExpression { SQLExpression(value: self) }
  }

  extension DatabaseValue: SQLSpecificExpressible {}

  public struct DatabaseValue: Hashable, Sendable, DatabaseValueConvertible, CustomStringConvertible
  {
    public enum Storage: Hashable, Sendable {
      case null
      case int64(Int64)
      case double(Double)
      case string(String)
      case blob(Data)

      /// Returns `Int64`, `Double`, `String`, `Data` or nil.
      public var value: (any DatabaseValueConvertible)? {
        switch self {
        case .null: nil
        case .int64(let n): n
        case .double(let d): d
        case .string(let s): s
        case .blob(let data): data
        }
      }
    }

    public let storage: Storage
    public static let null = Self(storage: .null)

    public init(storage: Storage) {
      self.storage = storage
    }

    public init?(_ value: Any) {
      guard let value = value as? any DatabaseValueConvertible else {
        return nil
      }
      self = value.databaseValue
    }

    public init?(value: Any) {
      self.init(value)
    }

    init(_ value: OrbitDatabaseValue) {
      switch value {
      case .null: storage = .null
      case .integer(let n): storage = .int64(n)
      case .real(let n): storage = .double(n)
      case .text(let s): storage = .string(s)
      case .blob(let bytes): storage = .blob(Data(bytes))
      }
    }

    var orbitValue: OrbitDatabaseValue {
      switch storage {
      case .null: .null
      case .int64(let n): .integer(n)
      case .double(let n): .real(n)
      case .string(let s): .text(s)
      case .blob(let data): .blob(Array(data))
      }
    }

    public var isNull: Bool {
      storage == .null
    }

    public var databaseValue: Self {
      self
    }

    public static func fromDatabaseValue(_ dbValue: Self) -> Self? {
      dbValue
    }

    var sqlLiteral: String {
      orbitValue.debugDescription
    }

    public var description: String {
      switch storage {
      case .null: "NULL"
      case .int64(let n): String(n)
      case .double(let n): String(n)
      case .string(let s): s.debugDescription
      case .blob(let data): "Data(\(data.count) bytes)"
      }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      switch (lhs.storage, rhs.storage) {
      case (.int64(let n), .double(let d)), (.double(let d), .int64(let n)): Int64(exactly: d) == n
      default: lhs.storage == rhs.storage
      }
    }

    public func hash(into hasher: inout Hasher) {
      switch storage {
      case .int64(let n):
        hasher.combine(0)
        hasher.combine(n)
      case .double(let d):
        if let n = Int64(exactly: d) {
          hasher.combine(0)
          hasher.combine(n)
        } else {
          hasher.combine(1)
          hasher.combine(d)
        }
      case .null: hasher.combine(2)
      case .string(let s):
        hasher.combine(3)
        hasher.combine(s)
      case .blob(let data):
        hasher.combine(4)
        hasher.combine(data)
      }
    }
  }

  extension DatabaseValueConvertible
  where Self: RawRepresentable, RawValue: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      rawValue.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      RawValue.fromDatabaseValue(dbValue).flatMap(Self.init(rawValue:))
    }
  }

  extension Optional: DatabaseValueConvertible, SQLExpressible
  where Wrapped: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      self?.databaseValue ?? .null
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      dbValue.isNull ? .some(.none) : Wrapped.fromDatabaseValue(dbValue).map { .some($0) }
    }
  }

  extension Bool: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      Int64(self ? 1 : 0).databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Bool? {
      switch dbValue.storage {
      case .int64(let n): n != 0
      case .double(let n): n != 0
      default: nil
      }
    }
  }

  extension String: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      .init(storage: .string(self))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> String? {
      switch dbValue.storage {
      case .string(let s): s
      case .blob(let data): String(data: data, encoding: .utf8)
      default: nil
      }
    }
  }

  extension Data: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      .init(storage: .blob(self))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Data? {
      switch dbValue.storage {
      case .blob(let data): data
      case .string(let s): Data(s.utf8)
      default: nil
      }
    }
  }

  extension Double: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      .init(storage: .double(self))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Double? {
      switch dbValue.storage {
      case .int64(let n): Double(n)
      case .double(let n): n
      default: nil
      }
    }
  }

  extension Float: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      Double(self).databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Float? {
      Double.fromDatabaseValue(dbValue).map(Float.init)
    }
  }

  extension UUID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      var bytes = uuid
      return withUnsafeBytes(of: &bytes) { Data($0).databaseValue }
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> UUID? {
      switch dbValue.storage {
      case .string(let s): return UUID(uuidString: s)
      case .blob(let data):
        guard data.count == 16 else {
          return nil
        }
        return data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
      default: return nil
      }
    }
  }

  extension Date: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      dateFormatter().string(from: self).databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Date? {
      if let components = DatabaseDateComponents.fromDatabaseValue(dbValue) {
        return Date(databaseDateComponents: components)
      }
      if let timestamp = Double.fromDatabaseValue(dbValue) {
        return Date(timeIntervalSince1970: timestamp)
      }
      return nil
    }
  }

  func dateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }

  // GRDB reads integers exactly and doubles after rounding toward zero, when representable.
  private func integer<T: FixedWidthInteger>(from dbValue: DatabaseValue) -> T? {
    switch dbValue.storage {
    case .int64(let n):
      return T(exactly: n)
    case .double(let n):
      guard n >= Double(Int64.min), n < Double(Int64.max) else { return nil }
      return T(exactly: Int64(n))
    default:
      return nil
    }
  }

  extension Int: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension Int8: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension Int16: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension Int32: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension Int64: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension UInt: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension UInt8: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension UInt16: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension UInt32: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension UInt64: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      guard let value = Int64(exactly: self) else {
        preconditionFailure("integer does not fit in SQLite's Int64")
      }
      return .init(storage: .int64(value))
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      integer(from: dbValue)
    }
  }

  extension URL: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      absoluteString.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> URL? {
      String.fromDatabaseValue(dbValue).flatMap(URL.init(string:))
    }
  }

#endif
