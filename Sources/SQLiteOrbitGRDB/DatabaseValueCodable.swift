#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // Default DatabaseValueConvertible conformances for Codable types, as in GRDB: values that
  // encode a single value are stored as that value; other values are stored as JSON text.

  extension DatabaseValueConvertible where Self: Encodable {
    public var databaseValue: DatabaseValue {
      var result = DatabaseValue.null
      try! SingleDatabaseValueEncoder(jsonEncoder: Self.databaseJSONEncoder()) { result = $0 }
        .encodeValue(self)
      return result
    }
  }

  extension DatabaseValueConvertible where Self: Decodable {
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      do {
        return try Self(from: SingleDatabaseValueDecoder(dbValue: dbValue))
      } catch is JSONRequiredError {
        guard let data = Data.fromDatabaseValue(dbValue) else { return nil }
        return try? databaseJSONDecoder().decode(Self.self, from: data)
      } catch {
        return nil
      }
    }
  }

  extension DatabaseValueConvertible
  where Self: Encodable & RawRepresentable, RawValue: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      rawValue.databaseValue
    }
  }

  extension DatabaseValueConvertible
  where Self: Decodable & RawRepresentable, RawValue: DatabaseValueConvertible {
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
      RawValue.fromDatabaseValue(dbValue).flatMap(Self.init(rawValue:))
    }
  }

  private struct JSONRequiredError: Error {}

  // MARK: - Encoding

  private final class SingleDatabaseValueEncoder: Encoder {
    let jsonEncoder: JSONEncoder
    let store: (DatabaseValue) -> Void
    var requiresJSON = false
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(jsonEncoder: JSONEncoder, store: @escaping (DatabaseValue) -> Void) {
      self.jsonEncoder = jsonEncoder
      self.store = store
    }

    func encodeValue<T: Encodable>(_ value: T) throws {
      do {
        try value.encode(to: self)
        if requiresJSON { throw JSONRequiredError() }
      } catch is JSONRequiredError {
        let data = try jsonEncoder.encode(value)
        store(String(decoding: data, as: UTF8.self).databaseValue)
      }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
      // Keyed values need JSON. Containers cannot throw, so record the need and discard.
      requiresJSON = true
      return KeyedEncodingContainer(DiscardingKeyedContainer<Key>())
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
      requiresJSON = true
      return DiscardingUnkeyedContainer()
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
      SingleDatabaseValueEncodingContainer(encoder: self)
    }
  }

  private struct SingleDatabaseValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: SingleDatabaseValueEncoder
    var codingPath: [any CodingKey] { [] }

    mutating func encodeNil() throws { encoder.store(.null) }

    mutating func encode<T: Encodable>(_ value: T) throws {
      if let value = value as? any DatabaseValueConvertible {
        // Prefer database encoding, which stores Date as text, for example.
        encoder.store(value.databaseValue)
      } else {
        try SingleDatabaseValueEncoder(jsonEncoder: encoder.jsonEncoder, store: encoder.store)
          .encodeValue(value)
      }
    }
  }

  private struct DiscardingKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    var codingPath: [any CodingKey] { [] }
    mutating func encodeNil(forKey key: Key) throws { throw JSONRequiredError() }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
      throw JSONRequiredError()
    }
    mutating func nestedContainer<NestedKey: CodingKey>(
      keyedBy keyType: NestedKey.Type,
      forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
      KeyedEncodingContainer(DiscardingKeyedContainer<NestedKey>())
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
      DiscardingUnkeyedContainer()
    }
    mutating func superEncoder() -> any Encoder { DiscardingEncoder() }
    mutating func superEncoder(forKey key: Key) -> any Encoder { DiscardingEncoder() }
  }

  private struct DiscardingUnkeyedContainer: UnkeyedEncodingContainer {
    var codingPath: [any CodingKey] { [] }
    var count: Int { 0 }
    mutating func encodeNil() throws { throw JSONRequiredError() }
    mutating func encode<T: Encodable>(_ value: T) throws { throw JSONRequiredError() }
    mutating func nestedContainer<NestedKey: CodingKey>(
      keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
      KeyedEncodingContainer(DiscardingKeyedContainer<NestedKey>())
    }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
      DiscardingUnkeyedContainer()
    }
    mutating func superEncoder() -> any Encoder { DiscardingEncoder() }
  }

  private struct DiscardingEncoder: Encoder {
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
      KeyedEncodingContainer(DiscardingKeyedContainer<Key>())
    }
    func unkeyedContainer() -> any UnkeyedEncodingContainer { DiscardingUnkeyedContainer() }
    func singleValueContainer() -> any SingleValueEncodingContainer {
      DiscardingSingleValueContainer()
    }
  }

  private struct DiscardingSingleValueContainer: SingleValueEncodingContainer {
    var codingPath: [any CodingKey] { [] }
    mutating func encodeNil() throws { throw JSONRequiredError() }
    mutating func encode<T: Encodable>(_ value: T) throws { throw JSONRequiredError() }
  }

  // MARK: - Decoding

  private struct SingleDatabaseValueDecoder: Decoder {
    let dbValue: DatabaseValue
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
      throw JSONRequiredError()
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
      throw JSONRequiredError()
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
      SingleDatabaseValueDecodingContainer(dbValue: dbValue)
    }
  }

  private struct SingleDatabaseValueDecodingContainer: SingleValueDecodingContainer {
    let dbValue: DatabaseValue
    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { dbValue.isNull }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
      if let type = T.self as? any DatabaseValueConvertible.Type {
        // Prefer database decoding, which reads Date from text, for example.
        guard let value = type.fromDatabaseValue(dbValue) else {
          throw DecodingError.dataCorruptedError(in: self, debugDescription: "value mismatch")
        }
        return value as! T
      }
      return try T(from: SingleDatabaseValueDecoder(dbValue: dbValue))
    }

    func decode(_ type: Bool.Type) throws -> Bool { try decodeValue(type) }
    func decode(_ type: String.Type) throws -> String { try decodeValue(type) }
    func decode(_ type: Double.Type) throws -> Double { try decodeValue(type) }
    func decode(_ type: Float.Type) throws -> Float { try decodeValue(type) }
    func decode(_ type: Int.Type) throws -> Int { try decodeValue(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decodeValue(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decodeValue(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decodeValue(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decodeValue(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try decodeValue(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeValue(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeValue(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeValue(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeValue(type) }

    private func decodeValue<T: DatabaseValueConvertible>(_ type: T.Type) throws -> T {
      guard let value = T.fromDatabaseValue(dbValue) else {
        throw DecodingError.dataCorruptedError(in: self, debugDescription: "value mismatch")
      }
      return value
    }
  }
#endif
