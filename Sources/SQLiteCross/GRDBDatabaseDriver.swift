#if GRDB
  import Foundation
  import GRDB
  import GRDBSQLite
  import StructuredQueries

  /// A ``DatabaseDriver`` backed by a GRDB database writer.
  public final class GRDBDatabaseDriver: DatabaseDriver, Sendable {
    public typealias ReadTransaction = GRDBReadTransaction
    public typealias WriteTransaction = GRDBWriteTransaction

    public let defaultIdentifier: DatabaseIdentifier
    public let writer: any DatabaseWriter

    public init(
      writer: any DatabaseWriter,
      identifier: DatabaseIdentifier? = nil
    ) {
      self.writer = writer
      self.defaultIdentifier = identifier ?? Self.makeDefaultIdentifier(path: writer.path)
    }

    public func read<Result: Sendable>(
      _ body: @Sendable (borrowing GRDBReadTransaction) throws -> sending Result
    ) async throws -> sending Result {
      try await writer.read { database in
        let transaction = GRDBReadTransaction(database: database)
        return try body(transaction)
      }
    }

    public func write<Result: Sendable>(
      _ body: @Sendable (borrowing GRDBWriteTransaction) throws -> sending Result
    ) async throws -> sending Result {
      try await writer.write { database in
        let transaction = GRDBWriteTransaction(database: database)
        return try body(transaction)
      }
    }

    private static func makeDefaultIdentifier(path: String) -> DatabaseIdentifier {
      guard !path.isEmpty, path != ":memory:" else { return .unique() }
      let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
      return DatabaseIdentifier(rawValue: canonicalPath)
    }
  }

  /// A read transaction lent by ``GRDBDatabaseDriver``.
  public struct GRDBReadTransaction: DatabaseReadTransaction, ~Copyable, ~Escapable {
    public typealias Row = GRDBDatabaseRow
    public typealias RowCursor = GRDBDatabaseRowCursor

    private let database: Database

    @_lifetime(borrow database)
    fileprivate init(database: borrowing Database) {
      self.database = copy database
    }

    @_lifetime(borrow self)
    public borrowing func rowCursor<S: DatabaseReadStatement>(
      _ statement: S
    ) throws -> GRDBDatabaseRowCursor {
      try makeGRDBCursor(statement.query, database: database)
    }
  }

  /// A write transaction lent by ``GRDBDatabaseDriver``.
  public struct GRDBWriteTransaction: DatabaseWriteTransaction, ~Copyable, ~Escapable {
    public typealias Row = GRDBDatabaseRow
    public typealias RowCursor = GRDBDatabaseRowCursor

    private let database: Database

    @_lifetime(borrow database)
    fileprivate init(database: borrowing Database) {
      self.database = copy database
    }

    @_lifetime(borrow self)
    public borrowing func rowCursor<S: DatabaseReadStatement>(
      _ statement: S
    ) throws -> GRDBDatabaseRowCursor {
      try makeGRDBCursor(statement.query, database: database)
    }

    @_lifetime(borrow self)
    public borrowing func executeRowCursor<S: DatabaseWriteStatement>(
      _ statement: S
    ) throws -> GRDBDatabaseRowCursor {
      try makeGRDBCursor(statement.query, database: database)
    }

    @discardableResult
    public borrowing func execute<S: DatabaseWriteStatement>(_ statement: S) throws -> Int {
      let prepared = try prepareGRDBQuery(statement.query)
      let statement = try database.makeStatement(sql: prepared.sql)
      try statement.execute(arguments: prepared.arguments)
      return database.changesCount
    }
  }

  @_lifetime(borrow database)
  private func makeGRDBCursor(
    _ query: QueryFragment,
    database: borrowing Database
  ) throws -> GRDBDatabaseRowCursor {
    let prepared = try prepareGRDBQuery(query)
    let statement = try database.makeStatement(sql: prepared.sql)
    let cursor = try GRDB.Row.fetchCursor(statement, arguments: prepared.arguments)
    return GRDBDatabaseRowCursor(cursor: cursor)
  }

  private func prepareGRDBQuery(
    _ query: QueryFragment
  ) throws -> (sql: String, arguments: StatementArguments) {
    let prepared = query.prepare { _ in "?" }
    let values = try prepared.bindings.map(GRDBBinding.init)
    return (prepared.sql, StatementArguments(values.map(\.value)))
  }

  /// A transaction-scoped cursor over GRDB result rows.
  public struct GRDBDatabaseRowCursor: DatabaseRowCursor, ~Copyable, ~Escapable {
    public typealias Row = GRDBDatabaseRow

    fileprivate let cursor: GRDB.RowCursor

    @_lifetime(immortal)
    fileprivate init(
      cursor: consuming GRDB.RowCursor
    ) {
      self.cursor = cursor
    }

    @_lifetime(&self)
    public mutating func next() throws -> GRDBDatabaseRow? {
      guard try cursor.next() != nil else { return nil }
      return GRDBDatabaseRow(cursor: self)
    }

    public mutating func forEach(
      _ body: (inout GRDBDatabaseRow) throws -> Void
    ) throws {
      let cursor = self.cursor
      try cursor.forEach { _ in
        let statement = cursor._statement
        var row = GRDBDatabaseRow(statement: statement)
        try body(&row)
      }
    }
  }

  /// A result row lent by a GRDB transaction.
  public struct GRDBDatabaseRow: DatabaseRow, ~Copyable, ~Escapable {
    @usableFromInline
    let statement: SQLiteStatement

    @_lifetime(borrow statement)
    fileprivate init(statement: borrowing GRDB.Statement) {
      self.statement = statement.sqliteStatement
    }

    @_lifetime(borrow cursor)
    fileprivate init(cursor: borrowing GRDBDatabaseRowCursor) {
      self.statement = cursor.cursor._statement.sqliteStatement
    }

    @inlinable
    public mutating func decode<Value: QueryRepresentable>(
      _ type: Value.Type
    ) throws -> Value.QueryOutput {
      var decoder = GRDBQueryDecoder(statement: statement)
      return try Value(decoder: &decoder).queryOutput
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @inlinable
    public mutating func decode<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> (repeat (each Value).QueryOutput) {
      var decoder = GRDBQueryDecoder(statement: statement)
      return try decoder.decodeColumns((repeat each Value).self)
    }
  }

  private struct GRDBBinding {
    let value: (any DatabaseValueConvertible)?

    init(_ binding: QueryBinding) throws {
      switch binding {
      case .blob(let bytes):
        value = Data(bytes)
      case .bool(let bool):
        value = Int64(bool ? 1 : 0)
      case .date(let date):
        value = date.sqliteCrossISO8601String
      case .double(let double):
        value = double
      case .int(let integer):
        value = integer
      case .null:
        value = nil
      case .text(let string):
        value = string
      case .uint(let integer):
        guard integer <= UInt64(Int64.max) else {
          throw DatabaseIntegerOverflowError(value: integer)
        }
        value = Int64(integer)
      case .uuid(let uuid):
        value = uuid.uuidString.lowercased()
      case .invalid(let error):
        throw error.underlyingError
      }
    }
  }

  /// Decodes Structured Queries values directly from SQLite's current result row.
  ///
  /// This intentionally mirrors SQLiteData's decoder so primitive reads can be inlined and avoid
  /// allocating intermediate GRDB `DatabaseValue` instances.
  @usableFromInline
  struct GRDBQueryDecoder: QueryDecoder {
    @usableFromInline
    let statement: SQLiteStatement

    @usableFromInline
    var currentIndex: Int32 = 0

    @usableFromInline
    init(statement: SQLiteStatement) {
      self.statement = statement
    }

    @inlinable
    mutating func decode(
      _ columnType: [UInt8].Type
    ) throws(QueryDecodingError) -> [UInt8]? {
      switch sqlite3_column_type(statement, currentIndex) {
      case SQLITE_NULL:
        currentIndex += 1
        return nil
      case SQLITE_BLOB:
        break
      default:
        throw QueryDecodingError.typeMismatch([UInt8].self)
      }
      defer { currentIndex += 1 }
      return [UInt8](
        UnsafeRawBufferPointer(
          start: sqlite3_column_blob(statement, currentIndex),
          count: Int(sqlite3_column_bytes(statement, currentIndex))
        )
      )
    }

    @inlinable
    mutating func decode(
      _ columnType: Double.Type
    ) throws(QueryDecodingError) -> Double? {
      switch sqlite3_column_type(statement, currentIndex) {
      case SQLITE_NULL:
        currentIndex += 1
        return nil
      case SQLITE_FLOAT:
        break
      default:
        throw QueryDecodingError.typeMismatch(Double.self)
      }
      defer { currentIndex += 1 }
      return sqlite3_column_double(statement, currentIndex)
    }

    @inlinable
    mutating func decode(
      _ columnType: Int64.Type
    ) throws(QueryDecodingError) -> Int64? {
      switch sqlite3_column_type(statement, currentIndex) {
      case SQLITE_NULL:
        currentIndex += 1
        return nil
      case SQLITE_INTEGER:
        break
      default:
        throw QueryDecodingError.typeMismatch(Int64.self)
      }
      defer { currentIndex += 1 }
      return sqlite3_column_int64(statement, currentIndex)
    }

    @inlinable
    mutating func decode(
      _ columnType: UInt64.Type
    ) throws(QueryDecodingError) -> UInt64? {
      guard let value = try decode(Int64.self) else { return nil }
      guard value >= 0 else {
        throw QueryDecodingError.other(DatabaseIntegerOverflowError(value: value))
      }
      return UInt64(value)
    }

    @inlinable
    mutating func decode(
      _ columnType: String.Type
    ) throws(QueryDecodingError) -> String? {
      switch sqlite3_column_type(statement, currentIndex) {
      case SQLITE_NULL:
        currentIndex += 1
        return nil
      case SQLITE_TEXT:
        break
      default:
        throw QueryDecodingError.typeMismatch(String.self)
      }
      defer { currentIndex += 1 }
      let text = sqlite3_column_text(statement, currentIndex)
      let byteCount = Int(sqlite3_column_bytes(statement, currentIndex))
      return String(
        decoding: UnsafeBufferPointer(start: text, count: byteCount),
        as: UTF8.self
      )
    }

    @inlinable
    mutating func decode(
      _ columnType: Bool.Type
    ) throws(QueryDecodingError) -> Bool? {
      try decode(Int64.self).map { $0 != 0 }
    }

    @inlinable
    mutating func decode(
      _ columnType: Int.Type
    ) throws(QueryDecodingError) -> Int? {
      try decode(Int64.self).map(Int.init)
    }

    @inlinable
    mutating func decode(
      _ columnType: Date.Type
    ) throws(QueryDecodingError) -> Date? {
      guard let value = try decode(String.self) else { return nil }
      do {
        return try Date(sqliteCrossISO8601String: value)
      } catch {
        throw QueryDecodingError.other(error)
      }
    }

    @inlinable
    mutating func decode(
      _ columnType: UUID.Type
    ) throws(QueryDecodingError) -> UUID? {
      switch sqlite3_column_type(statement, currentIndex) {
      case SQLITE_NULL:
        currentIndex += 1
        return nil
      case SQLITE_TEXT:
        break
      default:
        throw QueryDecodingError.typeMismatch(UUID.self)
      }
      defer { currentIndex += 1 }
      let text = sqlite3_column_text(statement, currentIndex)
      let byteCount = Int(sqlite3_column_bytes(statement, currentIndex))
      let utf8 = UnsafeBufferPointer(start: text, count: byteCount)
      if let uuid = UUID(sqliteCrossUTF8: utf8) {
        return uuid
      }
      guard let uuid = UUID(uuidString: String(decoding: utf8, as: UTF8.self)) else {
        throw QueryDecodingError.other(InvalidDatabaseUUIDError())
      }
      return uuid
    }
  }

  @usableFromInline
  struct DatabaseIntegerOverflowError<Value: Sendable>: Error {
    @usableFromInline
    let value: Value

    @usableFromInline
    init(value: Value) {
      self.value = value
    }
  }

  extension Date {
    @usableFromInline
    var sqliteCrossISO8601String: String {
      formatted(.iso8601.sqliteCrossCurrentTimestamp(includingFractionalSeconds: true))
    }

    @usableFromInline
    init(sqliteCrossISO8601String string: String) throws {
      do {
        try self.init(
          string,
          strategy: .iso8601.sqliteCrossCurrentTimestamp(includingFractionalSeconds: true)
        )
      } catch {
        try self.init(
          string,
          strategy: .iso8601.sqliteCrossCurrentTimestamp(includingFractionalSeconds: false)
        )
      }
    }
  }

  extension Date.ISO8601FormatStyle {
    @usableFromInline
    func sqliteCrossCurrentTimestamp(
      includingFractionalSeconds: Bool
    ) -> Self {
      year().month().day()
        .dateTimeSeparator(.space)
        .time(includingFractionalSeconds: includingFractionalSeconds)
    }
  }

  extension UUID {
    @usableFromInline
    init?(sqliteCrossUTF8 utf8: UnsafeBufferPointer<UInt8>) {
      guard utf8.count == 36 else { return nil }
      var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
      let parsed = withUnsafeMutableBytes(of: &raw) { bytes in
        var index = 0
        for byteIndex in 0..<16 {
          if byteIndex == 4 || byteIndex == 6 || byteIndex == 8 || byteIndex == 10 {
            guard utf8[index] == UInt8(ascii: "-") else { return false }
            index += 1
          }
          guard
            let high = sqliteCrossHexValue(utf8[index]),
            let low = sqliteCrossHexValue(utf8[index + 1])
          else { return false }
          bytes[byteIndex] = high << 4 | low
          index += 2
        }
        return true
      }
      guard parsed else { return nil }
      self.init(uuid: raw)
    }
  }

  @usableFromInline
  func sqliteCrossHexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
      byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"):
      byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"):
      byte - UInt8(ascii: "A") + 10
    default:
      nil
    }
  }

  @usableFromInline
  struct InvalidDatabaseUUIDError: Error {
    @usableFromInline
    init() {}
  }
#endif
