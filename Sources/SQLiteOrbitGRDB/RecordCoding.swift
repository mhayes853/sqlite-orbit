#if canImport(Foundation) && canImport(Dispatch)
  @preconcurrency import Foundation

  public struct PersistenceContainer: RandomAccessCollection, Sendable {
    var fields: [(String, DatabaseValue)] = []

    public init() {}

    public init(_ record: some EncodableRecord) throws {
      try record.encode(to: &self)
    }

    public var startIndex: Int {
      0
    }

    public var endIndex: Int {
      fields.count
    }

    public func index(after i: Int) -> Int {
      i + 1
    }

    public func index(before i: Int) -> Int {
      i - 1
    }

    public subscript(position: Int) -> (String, DatabaseValue) {
      fields[position]
    }

    public subscript(_ column: String) -> (any DatabaseValueConvertible)? {
      get {
        fields.first { $0.0.caseInsensitiveCompare(column) == .orderedSame }?.1
      }
      set {
        let value = newValue?.databaseValue ?? .null
        if let index = fields.firstIndex(where: {
          $0.0.caseInsensitiveCompare(column) == .orderedSame
        }) {
          fields[index].1 = value
        } else {
          fields.append((column, value))
        }
      }
    }

    public subscript(_ column: Column) -> (any DatabaseValueConvertible)? {
      get {
        self[column.name]
      }
      set {
        self[column.name] = newValue
      }
    }
  }

  public protocol EncodableRecord {
    func encode(to container: inout PersistenceContainer) throws

    static var databaseEncodingUserInfo: [CodingUserInfoKey: Any] { get }

    static func databaseJSONEncoder(for column: String) -> JSONEncoder

    static func databaseDataEncodingStrategy(for column: String) -> DatabaseDataEncodingStrategy

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { get }
  }

  public protocol FetchableRecord {
    init(row: Row) throws

    static var databaseDecodingUserInfo: [CodingUserInfoKey: Any] { get }

    static func databaseJSONDecoder(for column: String) -> JSONDecoder

    static func databaseDataDecodingStrategy(for column: String) -> DatabaseDataDecodingStrategy

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy

    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { get }
  }

  extension EncodableRecord {
    public static var databaseEncodingUserInfo: [CodingUserInfoKey: Any] {
      [:]
    }

    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
      .useDefaultKeys
    }

    public static func databaseDataEncodingStrategy(for column: String)
      -> DatabaseDataEncodingStrategy
    {
      .deferredToData
    }

    public static func databaseDateEncodingStrategy(for column: String)
      -> DatabaseDateEncodingStrategy
    {
      .deferredToDate
    }

    public static func databaseUUIDEncodingStrategy(for column: String)
      -> DatabaseUUIDEncodingStrategy
    {
      .deferredToUUID
    }

    public static func databaseJSONEncoder(for column: String) -> JSONEncoder {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      encoder.outputFormatting = .sortedKeys
      encoder.userInfo = databaseEncodingUserInfo
      return encoder
    }

    public var databaseDictionary: [String: DatabaseValue] {
      get throws {
        try Dictionary(uniqueKeysWithValues: PersistenceContainer(self).fields)
      }
    }

    public func databaseEquals(_ record: some EncodableRecord) -> Bool {
      guard let lhs = try? databaseDictionary, let rhs = try? record.databaseDictionary else {
        return false
      }
      return lhs.allSatisfy { rhs[$0.key] == $0.value }
    }

    public func databaseChanges(from record: some EncodableRecord) throws -> [String: DatabaseValue]
    {
      let previous = try record.databaseDictionary
      return try databaseDictionary.reduce(into: [:]) {
        if previous[$1.key] != $1.value {
          $0[$1.key] = previous[$1.key] ?? .null
        }
      }
    }
  }

  extension EncodableRecord where Self: Encodable {
    public func encode(to container: inout PersistenceContainer) throws {
      let encoder = RecordEncoder(record: Self.self)
      try encode(to: encoder)
      if let error = encoder.failure {
        throw error
      }
      container = encoder.container
    }
  }

  extension FetchableRecord {
    public static var databaseDecodingUserInfo: [CodingUserInfoKey: Any] {
      [:]
    }

    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
      .useDefaultKeys
    }

    public static func databaseDataDecodingStrategy(for column: String)
      -> DatabaseDataDecodingStrategy
    {
      .deferredToData
    }

    public static func databaseDateDecodingStrategy(for column: String)
      -> DatabaseDateDecodingStrategy
    {
      .deferredToDate
    }

    public static func databaseJSONDecoder(for column: String) -> JSONDecoder {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      decoder.userInfo = databaseDecodingUserInfo
      return decoder
    }

    public static func fetchAll(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> [Self] {
      try Array(fetchCursor(db, sql: sql, arguments: arguments))
    }

    public static func fetchOne(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> Self? {
      try Row.fetchOne(db, sql: sql, arguments: arguments).map(Self.init(row:))
    }

    public static func fetchCursor(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments()
    ) throws -> AnyCursor<Self> {
      try Row.fetchCursor(db, sql: sql, arguments: arguments).map(Self.init(row:))
    }

    public static func fetchAll(_ db: Database, _ literal: SQL) throws -> [Self] {
      try fetchAll(db, sql: literal.sql, arguments: literal.arguments)
    }

    public static func fetchOne(_ db: Database, _ literal: SQL) throws -> Self? {
      try fetchOne(db, sql: literal.sql, arguments: literal.arguments)
    }
  }

  extension FetchableRecord where Self: Decodable {
    public init(row: Row) throws {
      try self.init(from: RecordDecoder(row: row, record: Self.self))
    }
  }

  extension FetchableRecord where Self: TableRecord {
    public static func fetchAll(_ db: Database) throws -> [Self] {
      try all().fetchAll(db)
    }

    public static func fetchCursor(_ db: Database) throws -> AnyCursor<Self> {
      try all().fetchCursor(db)
    }

    public static func fetchOne(_ db: Database, key: (any DatabaseValueConvertible)?) throws
      -> Self?
    {
      try fetchOne(db, id: key)
    }

    public static func fetchAll<S: Sequence>(_ db: Database, keys: S) throws -> [Self]
    where S.Element: DatabaseValueConvertible {
      try fetchAll(db, ids: keys)
    }

    public static func fetchOne(_ db: Database, id: (any DatabaseValueConvertible)?) throws -> Self?
    {
      try all().filter(id: id).fetchOne(db)
    }

    public static func fetchOne(_ db: Database, key: [String: (any DatabaseValueConvertible)?])
      throws
      -> Self?
    {
      try all().filter(key: key).fetchOne(db)
    }

    public static func fetchAll<S: Sequence>(_ db: Database, ids: S) throws -> [Self]
    where S.Element: DatabaseValueConvertible {
      try all().filter(ids: ids).fetchAll(db)
    }

    public static func find(_ db: Database, id: any DatabaseValueConvertible) throws -> Self {
      guard let record = try fetchOne(db, id: id) else {
        throw RecordError.recordNotFound(
          databaseTableName: databaseTableName,
          key: ["id": id.databaseValue]
        )
      }
      return record
    }
  }

  public enum DatabaseDataEncodingStrategy: Sendable {
    case deferredToData, text
    case custom(@Sendable (Data) -> (any DatabaseValueConvertible)?)
  }

  public enum DatabaseDataDecodingStrategy: Sendable {
    case deferredToData
    case custom(@Sendable (DatabaseValue) -> Data?)
  }

  public enum DatabaseDateEncodingStrategy: @unchecked Sendable {
    case deferredToDate, timeIntervalSinceReferenceDate, timeIntervalSince1970, secondsSince1970,
      millisecondsSince1970, iso8601
    case formatted(DateFormatter)
    case custom(@Sendable (Date) -> (any DatabaseValueConvertible)?)
  }

  public enum DatabaseDateDecodingStrategy: @unchecked Sendable {
    case deferredToDate, timeIntervalSinceReferenceDate, timeIntervalSince1970,
      millisecondsSince1970,
      iso8601
    case formatted(DateFormatter)
    case custom(@Sendable (DatabaseValue) -> Date?)
  }

  public enum DatabaseUUIDEncodingStrategy: Sendable {
    case deferredToUUID, uppercaseString, lowercaseString
  }

  public enum DatabaseColumnEncodingStrategy: Sendable {
    case useDefaultKeys, convertToSnakeCase
    case custom(@Sendable (any CodingKey) -> String)

    func column(_ key: any CodingKey) -> String {
      switch self {
      case .useDefaultKeys: key.stringValue
      case .convertToSnakeCase: snakeCase(key.stringValue)
      case .custom(let convert): convert(key)
      }
    }
  }

  public enum DatabaseColumnDecodingStrategy: Sendable {
    case useDefaultKeys, convertFromSnakeCase
    case custom(@Sendable (String) -> any CodingKey)

    func key(_ column: String) -> String {
      switch self {
      case .useDefaultKeys: return column
      case .convertFromSnakeCase:
        let pieces = column.split(separator: "_", omittingEmptySubsequences: true)
        if pieces.count < 2 {
          return column
        }
        return (column.prefix { $0 == "_" }) + pieces[0].lowercased()
          + pieces.dropFirst().map { $0.capitalized }.joined()
          + column.reversed().prefix { $0 == "_" }.reversed()
      case .custom(let convert): return convert(column).stringValue
      }
    }
  }

  func snakeCase(_ key: String) -> String {
    var result = ""
    let characters = Array(key)
    for i in characters.indices {
      let c = characters[i]
      if c.isUppercase && i > 0
        && (characters[i - 1].isLowercase
          || (i + 1 < characters.count && characters[i + 1].isLowercase))
      {
        result += "_"
      }
      result += String(c).lowercased()
    }
    return result
  }

  private struct StringKey: CodingKey {
    let stringValue: String

    var intValue: Int? {
      Int(stringValue)
    }

    init(_ value: String) {
      stringValue = value
    }

    init?(stringValue: String) {
      self.init(stringValue)
    }

    init?(intValue: Int) {
      self.init(String(intValue))
    }
  }

  private final class RecordEncoder: Encoder {
    let record: any EncodableRecord.Type
    var container = PersistenceContainer()
    var failure: Error?
    var codingPath: [any CodingKey] = []

    var userInfo: [CodingUserInfoKey: Any] {
      record.databaseEncodingUserInfo
    }

    init(record: any EncodableRecord.Type) {
      self.record = record
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
      .init(RecordEncodingContainer(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
      failure = EncodingError.invalidValue(
        record,
        .init(codingPath: [], debugDescription: "database records must encode a keyed container")
      )
      return UnsupportedEncodingContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
      UnsupportedEncodingContainer(encoder: self)
    }

    func encode<T: Encodable>(_ value: T, key: any CodingKey) throws {
      let column = record.databaseColumnEncodingStrategy.column(key)
      let result: DatabaseValue
      if let date = value as? Date {
        result = encodeDatabaseDate(
          date,
          strategy: record.databaseDateEncodingStrategy(for: column)
        )
      } else if let data = value as? Data {
        result = try encodeDatabaseData(
          data,
          strategy: record.databaseDataEncodingStrategy(for: column)
        )
      } else if let uuid = value as? UUID {
        result = encodeDatabaseUUID(
          uuid,
          strategy: record.databaseUUIDEncodingStrategy(for: column)
        )
      } else if let convertible = value as? any DatabaseValueConvertible {
        result = convertible.databaseValue
      } else {
        let data = try record.databaseJSONEncoder(for: column).encode(value)
        let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if let string = json as? String {
          result = string.databaseValue
        } else if let number = json as? NSNumber {
          let kind = String(cString: number.objCType)
          result =
            kind == "d" || kind == "f"
            ? number.doubleValue.databaseValue : number.int64Value.databaseValue
        } else if json is NSNull {
          result = .null
        } else {
          result = String(decoding: data, as: UTF8.self).databaseValue
        }
      }
      container[column] = result
    }
  }

  private struct RecordEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: RecordEncoder

    var codingPath: [any CodingKey] {
      []
    }

    mutating func encodeNil(forKey key: Key) throws {
      encoder.container[encoder.record.databaseColumnEncodingStrategy.column(key)] =
        DatabaseValue.null
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
      keyedBy type: NestedKey.Type,
      forKey key: Key
    )
      -> KeyedEncodingContainer<NestedKey>
    {
      encoder.failure = EncodingError.invalidValue(
        key.stringValue,
        .init(
          codingPath: [key],
          debugDescription:
            "explicit nested containers require a custom PersistenceContainer encoder"
        )
      )
      return encoder.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
      encoder.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
      encoder
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
      encoder
    }
  }

  private struct UnsupportedEncodingContainer: SingleValueEncodingContainer,
    UnkeyedEncodingContainer
  {
    let encoder: RecordEncoder

    var codingPath: [any CodingKey] {
      []
    }

    var count: Int {
      0
    }

    private func unsupported(_ value: Any) -> EncodingError {
      .invalidValue(value, .init(codingPath: [], debugDescription: "records require keyed columns"))
    }

    mutating func encodeNil() throws {
      throw unsupported(NSNull())
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
      throw unsupported(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type)
      -> KeyedEncodingContainer<NestedKey>
    {
      encoder.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
      self
    }

    mutating func superEncoder() -> any Encoder {
      encoder
    }
  }

  private final class RecordDecoder: Decoder {
    let row: Row
    let record: any FetchableRecord.Type
    var codingPath: [any CodingKey] = []

    var userInfo: [CodingUserInfoKey: Any] {
      record.databaseDecodingUserInfo
    }

    init(row: Row, record: any FetchableRecord.Type) {
      self.row = row
      self.record = record
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
      .init(RecordDecodingContainer(decoder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
      throw DecodingError.typeMismatch(
        [Any].self,
        .init(codingPath: [], debugDescription: "records require keyed columns")
      )
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
      throw DecodingError.typeMismatch(
        Any.self,
        .init(codingPath: [], debugDescription: "records require keyed columns")
      )
    }

    func column(_ key: any CodingKey) -> String? {
      row.columnNames.first {
        record.databaseColumnDecodingStrategy.key($0).caseInsensitiveCompare(key.stringValue)
          == .orderedSame
      }
    }

    func decode<T: Decodable>(_ type: T.Type, key: any CodingKey) throws -> T {
      guard let column = column(key), let index = row.index(ofColumn: column) else {
        throw DecodingError.keyNotFound(
          key,
          .init(codingPath: [], debugDescription: "missing database column")
        )
      }
      let value = row.databaseValues[index]

      func mismatch() -> RowDecodingError {
        RowDecodingError(column: column, databaseValue: value, type: type)
      }
      if type == Date.self {
        let date: Date?
        switch record.databaseDateDecodingStrategy(for: column) {
        case .deferredToDate: date = Date.fromDatabaseValue(value)
        case .timeIntervalSince1970:
          date = Double.fromDatabaseValue(value).map(Date.init(timeIntervalSince1970:))
        case .timeIntervalSinceReferenceDate:
          date = Double.fromDatabaseValue(value).map(Date.init(timeIntervalSinceReferenceDate:))
        case .millisecondsSince1970:
          date = Double.fromDatabaseValue(value).map { Date(timeIntervalSince1970: $0 / 1000) }
        case .iso8601:
          date = String.fromDatabaseValue(value).flatMap { ISO8601DateFormatter().date(from: $0) }
        case .formatted(let formatter):
          date = String.fromDatabaseValue(value).flatMap(formatter.date(from:))
        case .custom(let convert): date = convert(value)
        }
        guard let date else {
          throw mismatch()
        }
        return date as! T
      }
      if type == Data.self {
        let data: Data?
        switch record.databaseDataDecodingStrategy(for: column) {
        case .deferredToData: data = Data.fromDatabaseValue(value)
        case .custom(let convert): data = convert(value)
        }
        guard let data else {
          throw mismatch()
        }
        return data as! T
      }
      if let convertible = type as? any DatabaseValueConvertible.Type {
        guard let decoded = convertible.fromDatabaseValue(value) as? T else {
          throw mismatch()
        }
        return decoded
      }
      // JSON-encoded arrays and objects use the record's per-column decoder. Scalar Codable enums
      // use a scalar decoder so a SQL string isn't mistaken for a JSON document.
      if let text = String.fromDatabaseValue(value), text.first == "{" || text.first == "[" {
        return try record.databaseJSONDecoder(for: column).decode(type, from: Data(text.utf8))
      }
      return try T(from: ColumnDecoder(value: value, path: [key], userInfo: userInfo))
    }
  }

  private struct RecordDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: RecordDecoder

    var codingPath: [any CodingKey] {
      []
    }

    var allKeys: [Key] {
      decoder.row.columnNames.compactMap {
        Key(stringValue: decoder.record.databaseColumnDecodingStrategy.key($0))
      }
    }

    func contains(_ key: Key) -> Bool {
      decoder.column(key) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
      guard let column = decoder.column(key), let index = decoder.row.index(ofColumn: column) else {
        return true
      }
      return decoder.row.databaseValues[index].isNull
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
      try decoder.decode(type, key: key)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
      -> KeyedDecodingContainer<NestedKey>
    {
      throw DecodingError.typeMismatch(
        type,
        .init(
          codingPath: [key],
          debugDescription: "explicit nested containers require a custom row decoder"
        )
      )
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
      try decoder.unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
      decoder
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
      decoder
    }
  }

  private struct ColumnDecoder: Decoder, SingleValueDecodingContainer {
    let value: DatabaseValue
    let path: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    var codingPath: [any CodingKey] {
      path
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
      self
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
      throw mismatch(type)
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
      throw mismatch([Any].self)
    }

    func decodeNil() -> Bool {
      value.isNull
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
      guard let convertible = type as? any DatabaseValueConvertible.Type,
        let decoded = convertible.fromDatabaseValue(value) as? T
      else {
        throw mismatch(type)
      }
      return decoded
    }

    private func decodeValue<T: DatabaseValueConvertible>(_ type: T.Type) throws -> T {
      guard let decoded = T.fromDatabaseValue(value) else {
        throw mismatch(type)
      }
      return decoded
    }

    func mismatch(_ type: Any.Type) -> DecodingError {
      .typeMismatch(
        type,
        .init(codingPath: path, debugDescription: "invalid database value \(value)")
      )
    }
  }

  extension RecordEncodingContainer {
    mutating func encode(_ value: Bool, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
      try encoder.encode(value, key: key)
    }

    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws {
      if let value {
        try encode(value, forKey: key)
      } else {
        try encodeNil(forKey: key)
      }
    }
  }

  extension RecordDecodingContainer {
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
      try decoder.decode(type, key: key)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
      try decoder.decode(type, key: key)
    }
  }

  extension UnsupportedEncodingContainer {
    mutating func encode(_ value: Bool) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: String) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: Double) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: Float) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: Int) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: Int8) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: Int16) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: Int32) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: Int64) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: UInt) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: UInt8) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: UInt16) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: UInt32) throws {
      throw unsupported(value)
    }

    mutating func encode(_ value: UInt64) throws {
      throw unsupported(value)
    }
  }

  extension ColumnDecoder {
    func decode(_ type: Bool.Type) throws -> Bool {
      return try decodeValue(type)
    }

    func decode(_ type: String.Type) throws -> String {
      return try decodeValue(type)
    }

    func decode(_ type: Double.Type) throws -> Double {
      return try decodeValue(type)
    }

    func decode(_ type: Float.Type) throws -> Float {
      return try decodeValue(type)
    }

    func decode(_ type: Int.Type) throws -> Int {
      return try decodeValue(type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
      return try decodeValue(type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
      return try decodeValue(type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
      return try decodeValue(type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
      return try decodeValue(type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
      return try decodeValue(type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
      return try decodeValue(type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
      return try decodeValue(type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
      return try decodeValue(type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
      return try decodeValue(type)
    }
  }

  func encodeDatabaseDate(_ date: Date, strategy: DatabaseDateEncodingStrategy) -> DatabaseValue {
    switch strategy {
    case .deferredToDate: date.databaseValue
    case .timeIntervalSince1970: date.timeIntervalSince1970.databaseValue
    case .timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.databaseValue
    case .secondsSince1970: Int64(date.timeIntervalSince1970.rounded(.down)).databaseValue
    case .millisecondsSince1970:
      Int64((date.timeIntervalSince1970 * 1000).rounded(.down)).databaseValue
    case .iso8601: ISO8601DateFormatter().string(from: date).databaseValue
    case .formatted(let formatter): formatter.string(from: date).databaseValue
    case .custom(let convert): convert(date)?.databaseValue ?? .null
    }
  }

  func encodeDatabaseData(_ data: Data, strategy: DatabaseDataEncodingStrategy) throws
    -> DatabaseValue
  {
    switch strategy {
    case .deferredToData: return data.databaseValue
    case .text:
      guard let text = String(data: data, encoding: .utf8) else {
        throw EncodingError.invalidValue(
          data,
          .init(codingPath: [], debugDescription: "data is not UTF-8")
        )
      }
      return text.databaseValue
    case .custom(let convert): return convert(data)?.databaseValue ?? .null
    }
  }

  func encodeDatabaseUUID(_ uuid: UUID, strategy: DatabaseUUIDEncodingStrategy) -> DatabaseValue {
    switch strategy {
    case .deferredToUUID: uuid.databaseValue
    case .uppercaseString: uuid.uuidString.uppercased().databaseValue
    case .lowercaseString: uuid.uuidString.lowercased().databaseValue
    }
  }

#endif
