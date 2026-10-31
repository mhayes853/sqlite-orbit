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

    public subscript(_ column: some ColumnExpression) -> (any DatabaseValueConvertible)? {
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
      try PersistenceContainer(self).changes(from: PersistenceContainer(record))
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
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> [Self] {
      try Array(fetchCursor(db, sql: sql, arguments: arguments, adapter: adapter))
    }

    public static func fetchOne(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> Self? {
      try Row.fetchOne(db, sql: sql, arguments: arguments, adapter: adapter).map(Self.init(row:))
    }

    public static func fetchCursor(
      _ db: Database,
      sql: String,
      arguments: StatementArguments = StatementArguments(),
      adapter: (any RowAdapter)? = nil
    ) throws -> AnyCursor<Self> {
      AnyCursor(
        try Row.fetchCursor(db, sql: sql, arguments: arguments, adapter: adapter)
          .map(Self.init(row:))
      )
    }

    public static func fetchAll(_ db: Database, _ literal: SQL) throws -> [Self] {
      let (sql, arguments) = try literal.build(db)
      return try fetchAll(db, sql: sql, arguments: arguments)
    }

    public static func fetchOne(_ db: Database, _ literal: SQL) throws -> Self? {
      let (sql, arguments) = try literal.build(db)
      return try fetchOne(db, sql: sql, arguments: arguments)
    }
  }

  extension FetchableRecord where Self: Decodable {
    public init(row: Row) throws {
      try self.init(from: RecordDecoder(row: row, record: Self.self))
    }
  }

  /// Decodes Decodable records from rows, as the default `FetchableRecord` initializer does.
  public class FetchableRecordDecoder {
    public init() {}

    /// Returns a record decoded from a row with the record's decoding strategies.
    public func decode<T: FetchableRecord & Decodable>(_ type: T.Type, from row: Row) throws -> T {
      try T(from: RecordDecoder(row: row, record: T.self))
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
      try find(db, key: id)
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

    // As in GRDB, a single value at the record level encodes the keyed columns of the value
    // into the record's container.
    func singleValueContainer() -> any SingleValueEncodingContainer {
      RecordSingleValueEncodingContainer(encoder: self)
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
      } else if let single = try singleValue(value, key: key, column: column) {
        result = single
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

  extension RecordEncoder {
    /// Encodes values that encode a single value (such as wrappers of strings), or returns nil
    /// for values that need keyed or unkeyed containers, which are stored as JSON.
    fileprivate func singleValue<T: Encodable>(_ value: T, key: any CodingKey, column: String)
      throws -> DatabaseValue?
    {
      let probe = ColumnValueEncoder(
        codingPath: codingPath + [key],
        userInfo: userInfo,
        record: record,
        column: column
      )
      try value.encode(to: probe)
      if probe.requiresJSON { return nil }
      return probe.value ?? .null
    }
  }

  private struct RecordSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: RecordEncoder

    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws {
      throw EncodingError.invalidValue(
        NSNull(),
        .init(codingPath: codingPath, debugDescription: "records require keyed columns")
      )
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
      if let record = value as? any EncodableRecord {
        try record.encode(to: &encoder.container)
      } else if value is any DatabaseValueConvertible {
        throw EncodingError.invalidValue(
          value,
          .init(codingPath: codingPath, debugDescription: "records require keyed columns")
        )
      } else {
        try value.encode(to: encoder)
      }
    }
  }

  /// Encodes a nested value that encodes a single value, and detects other values.
  private final class ColumnValueEncoder: Encoder, SingleValueEncodingContainer {
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let record: any EncodableRecord.Type
    let column: String
    var value: DatabaseValue?
    var requiresJSON = false

    init(
      codingPath: [any CodingKey],
      userInfo: [CodingUserInfoKey: Any],
      record: any EncodableRecord.Type,
      column: String
    ) {
      self.codingPath = codingPath
      self.userInfo = userInfo
      self.record = record
      self.column = column
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
      requiresJSON = true
      return KeyedEncodingContainer(DiscardingKeyedContainer<Key>(codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
      requiresJSON = true
      return DiscardingUnkeyedContainer(codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer { self }

    func encodeNil() throws { value = .null }

    func encode<T: Encodable>(_ value: T) throws {
      if let date = value as? Date {
        self.value = encodeDatabaseDate(
          date,
          strategy: record.databaseDateEncodingStrategy(for: column)
        )
      } else if let data = value as? Data {
        self.value = try encodeDatabaseData(
          data,
          strategy: record.databaseDataEncodingStrategy(for: column)
        )
      } else if let uuid = value as? UUID {
        self.value = encodeDatabaseUUID(
          uuid,
          strategy: record.databaseUUIDEncodingStrategy(for: column)
        )
      } else if let convertible = value as? any DatabaseValueConvertible {
        self.value = convertible.databaseValue
      } else {
        try value.encode(to: self)
      }
    }
  }

  private struct DiscardingKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let codingPath: [any CodingKey]
    mutating func encodeNil(forKey key: Key) throws {}
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {}
    mutating func nestedContainer<NestedKey: CodingKey>(
      keyedBy keyType: NestedKey.Type,
      forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
      KeyedEncodingContainer(DiscardingKeyedContainer<NestedKey>(codingPath: codingPath))
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
      DiscardingUnkeyedContainer(codingPath: codingPath)
    }
    mutating func superEncoder() -> any Encoder { DiscardingEncoder(codingPath: codingPath) }
    mutating func superEncoder(forKey key: Key) -> any Encoder {
      DiscardingEncoder(codingPath: codingPath)
    }
  }

  private struct DiscardingUnkeyedContainer: UnkeyedEncodingContainer {
    let codingPath: [any CodingKey]
    var count = 0
    mutating func encodeNil() throws { count += 1 }
    mutating func encode<T: Encodable>(_ value: T) throws { count += 1 }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type)
      -> KeyedEncodingContainer<NestedKey>
    {
      KeyedEncodingContainer(DiscardingKeyedContainer<NestedKey>(codingPath: codingPath))
    }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { self }
    mutating func superEncoder() -> any Encoder { DiscardingEncoder(codingPath: codingPath) }
  }

  private struct DiscardingEncoder: Encoder, SingleValueEncodingContainer {
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
      KeyedEncodingContainer(DiscardingKeyedContainer<Key>(codingPath: codingPath))
    }
    func unkeyedContainer() -> any UnkeyedEncodingContainer {
      DiscardingUnkeyedContainer(codingPath: codingPath)
    }
    func singleValueContainer() -> any SingleValueEncodingContainer { self }
    mutating func encodeNil() throws {}
    mutating func encode<T: Encodable>(_ value: T) throws {}
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
    let codingPath: [any CodingKey]
    let columnDecodingStrategy: DatabaseColumnDecodingStrategy
    /// The key, if any, that was decoded from the whole row, as GRDB allows for one key of
    /// a nested record type (`struct PlayerInfo: Decodable { var player: Player; ... }`).
    var decodedRootKey: String?

    var userInfo: [CodingUserInfoKey: Any] {
      record.databaseDecodingUserInfo
    }

    init(
      row: Row,
      record: any FetchableRecord.Type,
      codingPath: [any CodingKey] = [],
      columnDecodingStrategy: DatabaseColumnDecodingStrategy? = nil
    ) {
      self.row = row
      self.record = record
      self.codingPath = codingPath
      self.columnDecodingStrategy = columnDecodingStrategy ?? record.databaseColumnDecodingStrategy
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
      .init(RecordDecodingContainer(decoder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
      throw DecodingError.typeMismatch(
        [Any].self,
        .init(codingPath: codingPath, debugDescription: "records require keyed columns")
      )
    }

    // As in GRDB, a single value container at the record level decodes values from the whole
    // row: FetchableRecord types use their row initializer, other types decode keyed columns, and
    // scalars read the first column.
    func singleValueContainer() throws -> any SingleValueDecodingContainer {
      RecordSingleValueContainer(decoder: self)
    }

    func column(_ key: any CodingKey) -> String? {
      row.columnNames.first {
        columnDecodingStrategy.key($0).caseInsensitiveCompare(key.stringValue)
          == .orderedSame
      }
    }

    func decode<T: Decodable>(_ type: T.Type, key: any CodingKey) throws -> T {
      guard let column = column(key), let index = row.index(ofColumn: column) else {
        if let scoped = row.scopesTree[key.stringValue] {
          if let recordType = type as? any FetchableRecord.Type {
            return try recordType.init(row: scoped) as! T
          }
          return try T(
            from: RecordDecoder(
              row: scoped,
              record: record,
              codingPath: codingPath + [key],
              columnDecodingStrategy: .useDefaultKeys
            )
          )
        }
        if let rows = row.prefetchedRows[key.stringValue] {
          return try T(
            from: PrefetchedRowsDecoder(rows: rows, record: record, codingPath: codingPath + [key])
          )
        }
        let isScalar =
          type is any DatabaseValueConvertible.Type || type == Date.self || type == Data.self
        if !isScalar {
          if let rootKey = decodedRootKey {
            let keys = [rootKey, key.stringValue].sorted()
            throw DecodingError.keyNotFound(
              key,
              .init(
                codingPath: codingPath,
                debugDescription: "No such key: \(keys.joined(separator: " or "))"
              )
            )
          }
          // A nested record that is not a column, scope, or prefetched key decodes from the
          // whole row.
          decodedRootKey = key.stringValue
          if let recordType = type as? any FetchableRecord.Type {
            return try recordType.init(row: row) as! T
          }
          return try T(
            from: RecordDecoder(
              row: row,
              record: record,
              codingPath: codingPath + [key],
              columnDecodingStrategy: .useDefaultKeys
            )
          )
        }
        throw DecodingError.keyNotFound(
          key,
          .init(codingPath: codingPath, debugDescription: "missing database column")
        )
      }
      let value: DatabaseValue = row[index]
      if let decoded = try decodeColumnScalar(type, value: value, column: column, record: record) {
        return decoded
      }
      // JSON-encoded arrays and objects use the record's per-column decoder. Scalar Codable enums
      // use a scalar decoder so a SQL string isn't mistaken for a JSON document.
      if let text = String.fromDatabaseValue(value), text.first == "{" || text.first == "[" {
        return try record.databaseJSONDecoder(for: column).decode(type, from: Data(text.utf8))
      }
      return try T(
        from: ColumnDecoder(
          value: value,
          path: codingPath + [key],
          userInfo: userInfo,
          column: column,
          record: record
        )
      )
    }
  }

  // Decodes dates, data, and DatabaseValueConvertible values with the column's strategies.
  // Returns nil for other types.
  private func decodeColumnScalar<T>(
    _ type: T.Type,
    value: DatabaseValue,
    column: String,
    record: any FetchableRecord.Type
  ) throws -> T? {
    do {
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
      return nil
    }
  }

  private struct RecordSingleValueContainer: SingleValueDecodingContainer {
    let decoder: RecordDecoder

    var codingPath: [any CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool {
      !decoder.row.containsNonNullValue
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
      if let recordType = type as? any FetchableRecord.Type {
        return try recordType.init(row: decoder.row) as! T
      }
      if type is any DatabaseValueConvertible.Type || type == Date.self || type == Data.self,
        let column = decoder.row.columnNames.first
      {
        let value = decoder.row.databaseValues[0]
        if let decoded = try decodeColumnScalar(
          type,
          value: value,
          column: column,
          record: decoder.record
        ) {
          return decoded
        }
      }
      return try T(
        from: RecordDecoder(
          row: decoder.row,
          record: decoder.record,
          codingPath: decoder.codingPath,
          columnDecodingStrategy: .useDefaultKeys
        )
      )
    }
  }

  private struct RecordDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: RecordDecoder

    var codingPath: [any CodingKey] {
      decoder.codingPath
    }

    var allKeys: [Key] {
      let names = Set(decoder.row.columnNames.map { decoder.columnDecodingStrategy.key($0) })
        .union(decoder.row.scopesTree.names)
        .union(decoder.row.prefetchedRows.keys)
      return names.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool {
      decoder.column(key) != nil || decoder.row.scopesTree[key.stringValue] != nil
        || decoder.row.prefetchedRows[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
      guard let column = decoder.column(key), let index = decoder.row.index(ofColumn: column) else {
        if let scoped = decoder.row.scopesTree[key.stringValue] {
          return !scoped.containsNonNullValue
        }
        return decoder.row.prefetchedRows[key.stringValue] == nil
      }
      return decoder.row.hasNull(atIndex: index)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
      try decoder.decode(type, key: key)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
      -> KeyedDecodingContainer<NestedKey>
    {
      if decoder.column(key) == nil, let scoped = decoder.row.scopesTree[key.stringValue] {
        return try RecordDecoder(
          row: scoped,
          record: decoder.record,
          codingPath: codingPath + [key],
          columnDecodingStrategy: decoder.columnDecodingStrategy
        )
        .container(keyedBy: type)
      }
      throw DecodingError.typeMismatch(
        type,
        .init(
          codingPath: codingPath + [key],
          debugDescription: "no scoped keyed container for \(key.stringValue)"
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

  /// Decodes collections of prefetched rows (`[Book]`, `Set<Book>`, `[String]`).
  private struct PrefetchedRowsDecoder: Decoder, UnkeyedDecodingContainer {
    let rows: [Row]
    let record: any FetchableRecord.Type
    let codingPath: [any CodingKey]
    var currentIndex = 0

    init(rows: [Row], record: any FetchableRecord.Type, codingPath: [any CodingKey]) {
      self.rows = rows
      self.record = record
      self.codingPath = codingPath
    }

    var userInfo: [CodingUserInfoKey: Any] { record.databaseDecodingUserInfo }
    var count: Int? { rows.count }
    var isAtEnd: Bool { currentIndex >= rows.count }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
      throw DecodingError.typeMismatch(
        type,
        .init(codingPath: codingPath, debugDescription: "prefetched rows decode as a collection")
      )
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer { self }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
      throw DecodingError.typeMismatch(
        Any.self,
        .init(codingPath: codingPath, debugDescription: "prefetched rows decode as a collection")
      )
    }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
      defer { currentIndex += 1 }
      let strategy =
        (type as? any FetchableRecord.Type)?.databaseColumnDecodingStrategy ?? .useDefaultKeys
      return try T(
        from: RecordDecoder(
          row: rows[currentIndex],
          record: record,
          codingPath: codingPath,
          columnDecodingStrategy: strategy
        )
      )
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws
      -> KeyedDecodingContainer<NestedKey>
    {
      try container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { self }

    mutating func superDecoder() throws -> any Decoder { self }
  }

  private struct ColumnDecoder: Decoder, SingleValueDecodingContainer {
    let value: DatabaseValue
    let path: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    var column: String? = nil
    var record: (any FetchableRecord.Type)? = nil

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
      if let column, let record {
        // Nested single values keep the column's date and data strategies.
        if let decoded = try decodeColumnScalar(type, value: value, column: column, record: record)
        {
          return decoded
        }
      } else if let convertible = type as? any DatabaseValueConvertible.Type {
        guard let decoded = convertible.fromDatabaseValue(value) as? T else {
          throw mismatch(type)
        }
        return decoded
      }
      // A single value wrapping another single value, such as a struct around a string.
      return try T(from: self)
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
