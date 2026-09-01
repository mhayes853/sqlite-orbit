#if GRDB
  import Foundation
  import GRDB
  import GRDBSQLite
  import StructuredQueriesSQLite

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
      self.defaultIdentifier = identifier ?? Self.defaultIdentifier(path: writer.path)
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

    static func defaultIdentifier(path: String) -> DatabaseIdentifier {
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
    public borrowing func rowCursor(
      _ query: DatabaseQuery<DatabaseReadAccess>,
      cached: Bool
    ) throws -> GRDBDatabaseRowCursor {
      try makeGRDBCursor(query.fragment, database: database, cached: cached)
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
    public borrowing func rowCursor(
      _ query: DatabaseQuery<DatabaseReadAccess>,
      cached: Bool
    ) throws -> GRDBDatabaseRowCursor {
      try makeGRDBCursor(query.fragment, database: database, cached: cached)
    }

    @_lifetime(borrow self)
    public borrowing func rowCursor(
      _ query: DatabaseQuery<DatabaseWriteAccess>,
      cached: Bool
    ) throws -> GRDBDatabaseRowCursor {
      try makeGRDBCursor(query.fragment, database: database, cached: cached)
    }

    @discardableResult
    public borrowing func execute(_ query: DatabaseQuery<DatabaseWriteAccess>) throws -> Int {
      // A statement that builds no SQL changes nothing. Running a stand-in would leave
      // `changesCount` reporting whatever the previous statement changed.
      guard !query.fragment.isEmpty else { return 0 }
      let prepared = try prepareGRDBQuery(query.fragment)
      let statement = try database.cachedStatement(sql: prepared.sql)
      try statement.execute(arguments: prepared.arguments)
      return database.changesCount
    }
  }

  @_lifetime(borrow database)
  private func makeGRDBCursor(
    _ query: QueryFragment,
    database: borrowing Database,
    cached: Bool
  ) throws -> GRDBDatabaseRowCursor {
    let prepared = try prepareGRDBQuery(query)
    // A cached statement is shared by every cursor over the same SQL on this connection, so it is
    // only safe for callers that consume and discard the cursor before creating another.
    let statement =
      cached
      ? try database.cachedStatement(sql: prepared.sql)
      : try database.makeStatement(sql: prepared.sql)
    let cursor = try GRDB.Row.fetchCursor(statement, arguments: prepared.arguments)
    return GRDBDatabaseRowCursor(cursor: cursor)
  }

  private func prepareGRDBQuery(
    _ query: QueryFragment
  ) throws -> (sql: String, arguments: StatementArguments) {
    var (sql, bindings) = query.prepare { _ in "?" }
    if sql.isEmpty {
      // A query builder can legitimately produce no SQL, such as `Values` with no rows. SQLite
      // cannot prepare an empty string, so stand in a statement that selects nothing.
      sql = "SELECT 1 WHERE 0 -- empty query"
      bindings = []
    }
    let values = try bindings.map(GRDBBinding.init)
    return (sql, StatementArguments(values.map(\.value)))
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
  ///
  /// The row owns its decoder so that successive `decode` calls advance through the row's columns.
  /// Each row lent by a cursor starts over at the first column.
  public struct GRDBDatabaseRow: DatabaseRow, ~Copyable, ~Escapable {
    @usableFromInline
    var decoder: GRDBQueryDecoder

    @_lifetime(borrow statement)
    fileprivate init(statement: borrowing GRDB.Statement) {
      self.decoder = GRDBQueryDecoder(statement: statement.sqliteStatement)
    }

    @_lifetime(borrow cursor)
    fileprivate init(cursor: borrowing GRDBDatabaseRowCursor) {
      self.decoder = GRDBQueryDecoder(statement: cursor.cursor._statement.sqliteStatement)
    }

    @inlinable
    public mutating func decode<Value: QueryRepresentable>(
      _ type: Value.Type
    ) throws -> Value.QueryOutput {
      try Value(decoder: &decoder).queryOutput
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @inlinable
    public mutating func decode<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> (repeat (each Value).QueryOutput) {
      try decoder.decodeColumns((repeat each Value).self)
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

  extension CrossProcessDatabase where Driver == GRDBDatabaseDriver {
    /// Creates a cross-process database backed by an already-opened GRDB database writer.
    ///
    /// The caller owns the writer, so this initializer cannot coordinate opening it or guarantee
    /// that it is configured for multi-process access. Prefer ``init(path:configuration:id:coordination:onAnnouncementFailure:)``
    /// for databases other processes also open, and supply `transport` here only when reusing a
    /// writer that is already configured the same way.
    public convenience init(
      writer: any DatabaseWriter,
      id: DatabaseIdentifier? = nil,
      transport: (any DatabaseIPCTransport)? = nil,
      onAnnouncementFailure: (@Sendable (any Error) -> Void)? = nil
    ) {
      self.init(
        driver: GRDBDatabaseDriver(writer: writer),
        id: id,
        transport: transport,
        onAnnouncementFailure: onAnnouncementFailure
      )
    }
  }

  extension GRDB.Configuration {
    /// A configuration with the defaults a database shared between processes needs.
    ///
    /// GRDB reports `SQLITE_BUSY` immediately by default, which makes any write that overlaps
    /// another process's write fail outright. A busy timeout lets those writes queue instead.
    public static var crossProcess: Self {
      var configuration = Self()
      configuration.busyMode = .timeout(5)
      configuration.prepareDatabase { database in
        try database.execute(sql: "PRAGMA trusted_schema = OFF")
      }
      return configuration
    }
  }

  #if canImport(Darwin) || canImport(Glibc)
    extension CrossProcessDatabase where Driver == GRDBDatabaseDriver {
      /// Opens the SQLite database at `path` for access from any process using the same
      /// coordination directory.
      ///
      /// The database is opened as a GRDB `DatabasePool`, so it runs in WAL mode with concurrent
      /// readers and a single writer. Opening is serialized across processes by an exclusive lock,
      /// because moving a database into WAL mode briefly needs an exclusive lock of SQLite's own,
      /// which processes first opening the same database would otherwise contend for. The lock does
      /// not replace `configuration`'s busy timeout, which still covers contention the lock cannot
      /// cover, such as the checkpoint another process takes as it closes the database.
      ///
      /// - Parameters:
      ///   - path: The path of the SQLite database file.
      ///   - configuration: The GRDB configuration used to open the database.
      ///   - id: The identity shared by every process that opens this database. Defaults to the
      ///     database's standardized path.
      ///   - coordination: Describes the directory and back pressure this process uses to reach its
      ///     peers. Processes coordinate only when they share a coordination directory.
      ///   - onAnnouncementFailure: Receives the error when announcing a committed write fails.
      public convenience init(
        path: String,
        configuration: GRDB.Configuration = .crossProcess,
        id: DatabaseIdentifier? = nil,
        coordination: UnixDatagramDatabaseIPCTransport.Configuration = .default,
        onAnnouncementFailure: (@Sendable (any Error) -> Void)? = nil
      ) throws {
        let identifier = id ?? GRDBDatabaseDriver.defaultIdentifier(path: path)
        let pool = try DatabaseOpenLock.withLock(
          databaseIdentifier: identifier,
          directory: coordination.directory
        ) {
          try DatabasePool(path: path, configuration: configuration)
        }
        self.init(
          driver: GRDBDatabaseDriver(writer: pool, identifier: identifier),
          id: identifier,
          transport: try UnixDatagramDatabaseIPCTransport.shared(configuration: coordination),
          onAnnouncementFailure: onAnnouncementFailure
        )
      }
    }
  #endif
#endif
