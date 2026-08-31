#if GRDB
  import Foundation
  import GRDB
  import StructuredQueries

  /// A ``DatabaseDriver`` backed by a GRDB database writer.
  public final class GRDBDatabaseDriver: DatabaseDriver, Sendable {
    public typealias Transaction = GRDBDatabaseTransaction

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
      _ body: @Sendable (borrowing GRDBDatabaseTransaction) throws -> sending Result
    ) async throws -> sending Result {
      try await writer.read { database in
        let transaction = GRDBDatabaseTransaction(
          database: database,
          accessKind: .read
        )
        return try body(transaction)
      }
    }

    public func write<Result: Sendable>(
      _ body: @Sendable (borrowing GRDBDatabaseTransaction) throws -> sending Result
    ) async throws -> sending Result {
      try await writer.write { database in
        let transaction = GRDBDatabaseTransaction(
          database: database,
          accessKind: .write
        )
        return try body(transaction)
      }
    }

    private static func makeDefaultIdentifier(path: String) -> DatabaseIdentifier {
      guard !path.isEmpty, path != ":memory:" else { return .unique() }
      let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
      return .stable(for: canonicalPath)
    }
  }

  /// A transaction lent by ``GRDBDatabaseDriver``.
  public struct GRDBDatabaseTransaction: DatabaseTransaction, ~Copyable, ~Escapable {
    public typealias Row = GRDBDatabaseRow

    private let database: Database
    public let accessKind: DatabaseTransactionAccessKind

    @_lifetime(borrow database)
    fileprivate init(
      database: borrowing Database,
      accessKind: DatabaseTransactionAccessKind
    ) {
      self.database = copy database
      self.accessKind = accessKind
    }

    @discardableResult
    public borrowing func execute(_ query: QueryFragment) throws -> Int {
      let prepared = try prepare(query)
      let statement = try database.makeStatement(sql: prepared.sql)
      try statement.execute(arguments: prepared.arguments)
      return database.changesCount
    }

    public borrowing func query(
      _ query: QueryFragment,
      _ body: (inout GRDBDatabaseRow) throws -> DatabaseRowIteration
    ) throws {
      let prepared = try prepare(query)
      let statement = try database.makeStatement(sql: prepared.sql)
      let cursor = try GRDB.Row.fetchCursor(statement, arguments: prepared.arguments)
      while let row = try cursor.next() {
        var databaseRow = GRDBDatabaseRow(row: row)
        if try body(&databaseRow) == .stop {
          break
        }
      }
    }

    private borrowing func prepare(
      _ query: QueryFragment
    ) throws -> (sql: String, arguments: StatementArguments) {
      let prepared = query.prepare { _ in "?" }
      let values = try prepared.bindings.map(GRDBBinding.init)
      return (prepared.sql, StatementArguments(values.map(\.value)))
    }
  }

  /// A result row lent by ``GRDBDatabaseTransaction``.
  public struct GRDBDatabaseRow: DatabaseRow, ~Copyable, ~Escapable {
    private let row: GRDB.Row

    @_lifetime(borrow row)
    fileprivate init(row: borrowing GRDB.Row) {
      self.row = copy row
    }

    public mutating func decode<Value: QueryRepresentable>(
      _ type: Value.Type
    ) throws -> Value.QueryOutput {
      var decoder = GRDBQueryDecoder(row: row)
      return try Value(decoder: &decoder).queryOutput
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public mutating func decode<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> (repeat (each Value).QueryOutput) {
      var decoder = GRDBQueryDecoder(row: row)
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

  private struct GRDBQueryDecoder: QueryDecoder {
    let row: GRDB.Row
    var currentIndex = 0

    mutating func decode(_ columnType: [UInt8].Type) throws -> [UInt8]? {
      switch try currentValue() {
      case .null:
        currentIndex += 1
        return nil
      case .blob(let data):
        currentIndex += 1
        return Array(data)
      default:
        throw QueryDecodingError.typeMismatch([UInt8].self)
      }
    }

    mutating func decode(_ columnType: Double.Type) throws -> Double? {
      switch try currentValue() {
      case .null:
        currentIndex += 1
        return nil
      case .double(let value):
        currentIndex += 1
        return value
      default:
        throw QueryDecodingError.typeMismatch(Double.self)
      }
    }

    mutating func decode(_ columnType: Int64.Type) throws -> Int64? {
      switch try currentValue() {
      case .null:
        currentIndex += 1
        return nil
      case .int64(let value):
        currentIndex += 1
        return value
      default:
        throw QueryDecodingError.typeMismatch(Int64.self)
      }
    }

    mutating func decode(_ columnType: UInt64.Type) throws -> UInt64? {
      guard let value = try decode(Int64.self) else { return nil }
      guard value >= 0 else {
        throw QueryDecodingError.other(DatabaseIntegerOverflowError(value: value))
      }
      return UInt64(value)
    }

    mutating func decode(_ columnType: String.Type) throws -> String? {
      switch try currentValue() {
      case .null:
        currentIndex += 1
        return nil
      case .string(let value):
        currentIndex += 1
        return value
      default:
        throw QueryDecodingError.typeMismatch(String.self)
      }
    }

    mutating func decode(_ columnType: Bool.Type) throws -> Bool? {
      try decode(Int64.self).map { $0 != 0 }
    }

    mutating func decode(_ columnType: Int.Type) throws -> Int? {
      guard let value = try decode(Int64.self) else { return nil }
      guard let integer = Int(exactly: value) else {
        throw QueryDecodingError.other(DatabaseIntegerOverflowError(value: value))
      }
      return integer
    }

    mutating func decode(_ columnType: Date.Type) throws -> Date? {
      guard let value = try decode(String.self) else { return nil }
      do {
        return try Date(sqliteCrossISO8601String: value)
      } catch {
        throw QueryDecodingError.other(error)
      }
    }

    mutating func decode(_ columnType: UUID.Type) throws -> UUID? {
      guard let value = try decode(String.self) else { return nil }
      guard let uuid = UUID(uuidString: value) else {
        throw QueryDecodingError.typeMismatch(UUID.self)
      }
      return uuid
    }

    private func currentValue() throws -> DatabaseValue.Storage {
      guard currentIndex < row.count else {
        throw QueryDecodingError.missingRequiredColumn
      }
      let value: DatabaseValue = row[currentIndex]
      return value.storage
    }
  }

  private struct DatabaseIntegerOverflowError<Value: Sendable>: Error {
    let value: Value
  }

  extension Date {
    fileprivate var sqliteCrossISO8601String: String {
      formatted(.iso8601.sqliteCrossCurrentTimestamp(includingFractionalSeconds: true))
    }

    fileprivate init(sqliteCrossISO8601String string: String) throws {
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
    fileprivate func sqliteCrossCurrentTimestamp(
      includingFractionalSeconds: Bool
    ) -> Self {
      year().month().day()
        .dateTimeSeparator(.space)
        .time(includingFractionalSeconds: includingFractionalSeconds)
    }
  }
#endif
