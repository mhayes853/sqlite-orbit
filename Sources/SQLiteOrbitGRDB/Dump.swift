#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  // MARK: - Statements

  extension Statement: CustomStringConvertible {
    public var description: String { sql }
  }

  /// A cursor over the statements of an SQL script.
  public final class SQLStatementCursor: Cursor {
    private let database: Database
    private var remaining: String
    private var arguments: StatementArguments?
    private let originalSQL: String

    init(database: Database, sql: String, arguments: StatementArguments?) {
      self.database = database
      remaining = sql
      originalSQL = sql
      self.arguments = arguments
    }

    public func next() throws -> Statement? {
      let (text, remainder) = try translate { try database.access.firstStatement(remaining) }
      guard let text else {
        if let arguments, !arguments.values.isEmpty {
          throw DatabaseError(
            resultCode: .SQLITE_MISUSE,
            message: "wrong number of statement arguments: \(arguments.values.count)",
            sql: originalSQL
          )
        }
        return nil
      }
      remaining = remainder
      let statement = try Statement(database: database, sql: text, cached: false)
      if var arguments {
        let bound = try bindArguments(arguments, sql: text, allowRemaining: true)
        statement.arguments = StatementArguments(bound.values)
        arguments.consume(bound.consumed)
        self.arguments = arguments
      }
      return statement
    }
  }

  extension Database {
    /// Returns a cursor of the prepared statements of an SQL script.
    public func allStatements(sql: String, arguments: StatementArguments? = nil) throws
      -> SQLStatementCursor
    {
      SQLStatementCursor(database: self, sql: sql, arguments: arguments)
    }

    /// Returns a cursor of the prepared statements of an SQL literal.
    public func allStatements(literal: SQL) throws -> SQLStatementCursor {
      let (sql, arguments) = try literal.build(self)
      return SQLStatementCursor(
        database: self,
        sql: sql,
        arguments: arguments.isEmpty ? nil : arguments
      )
    }

    /// Whether a table name is reserved by SQLite.
    public static func isSQLiteInternalTable(_ tableName: String) -> Bool {
      tableName.starts(with: "sqlite_")
    }

    /// Whether a table name is reserved by GRDB.
    public static func isGRDBInternalTable(_ tableName: String) -> Bool {
      tableName.starts(with: "grdb_")
    }

    // `quote(value)`, without tracing.
    func quotedSQL(_ value: DatabaseValue) -> String {
      (try? translate {
        let cursor = try access.statementCursor(
          SQLiteOrbit.SQL(text: "SELECT quote(?)", bindings: [value.orbitValue])
        )
        defer { try? cursor.close() }
        return try cursor.next()?.first
          .flatMap { String.fromDatabaseValue(DatabaseValue($0.value)) }
      }) ?? "NULL"
    }
  }

  // MARK: - Dump formats

  /// A format of database dumps.
  public protocol DumpFormat {
    /// Writes the current row of the statement.
    mutating func writeRow(_ db: Database, statement: Statement, to stream: inout DumpStream) throws

    /// Writes what follows the last row of the statement.
    mutating func finalize(_ db: Database, statement: Statement, to stream: inout DumpStream)
  }

  /// The stream that dump formats write to.
  public struct DumpStream {
    var base: any TextOutputStream
    var needsMarginLine = false

    init(_ base: (any TextOutputStream)?) {
      self.base = base ?? StandardOutputStream()
    }

    /// Requests an empty line before the next written text.
    public mutating func margin() {
      needsMarginLine = true
    }
  }

  private struct StandardOutputStream: TextOutputStream {
    func write(_ string: String) {
      print(string, terminator: "")
    }
  }

  extension DumpStream: TextOutputStream {
    public mutating func write(_ string: String) {
      if needsMarginLine && !string.isEmpty {
        needsMarginLine = false
        if string.first != "\n" {
          base.write("\n")
        }
      }
      base.write(string)
    }

    mutating func writeln(_ string: String) {
      write(string)
      write("\n")
    }
  }

  extension Statement {
    // The dumped columns, which exclude GRDB's internal `grdb_` columns.
    fileprivate var dumpedColumns: [(name: String, value: DatabaseValue)] {
      guard let row = dumpedRow else { return [] }
      return zip(row.columnNames, row.databaseValues)
        .filter { !$0.0.starts(with: "grdb_") }
        .map { ($0.0, $0.1) }
    }
  }

  private func plainText(_ value: DatabaseValue, nullValue: String) -> String {
    switch value.storage {
    case .null: nullValue
    case .int64(let n): n.description
    case .double(let d): d.description
    case .string(let s): s
    case .blob(let data): String(decoding: data, as: UTF8.self)
    }
  }

  /// A dump format for debugging: values separated by `|`, blobs shown as text or UUIDs.
  public struct DebugDumpFormat: Sendable {
    public var header: Bool
    public var separator: String
    public var nullValue: String
    private var firstRow = true

    public init(header: Bool = false, separator: String = "|", nullValue: String = "") {
      self.header = header
      self.separator = separator
      self.nullValue = nullValue
    }
  }

  extension DebugDumpFormat: DumpFormat {
    public mutating func writeRow(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      if firstRow {
        firstRow = false
        if header {
          stream.writeln(statement.columnNames.joined(separator: separator))
        }
      }
      let values = statement.dumpedColumns.map { column -> String in
        guard case .blob(let data) = column.value.storage else {
          return plainText(column.value, nullValue: nullValue)
        }
        if let string = String(data: data, encoding: .utf8) {
          return string
        }
        if data.count == 16, let uuid = UUID.fromDatabaseValue(column.value) {
          return uuid.uuidString
        }
        return db.quotedSQL(column.value)
      }
      stream.writeln(values.joined(separator: separator))
    }

    public mutating func finalize(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      firstRow = true
    }
  }

  extension DumpFormat where Self == DebugDumpFormat {
    /// The debug format.
    public static func debug(header: Bool = false, separator: String = "|", nullValue: String = "")
      -> Self
    {
      DebugDumpFormat(header: header, separator: separator, nullValue: nullValue)
    }
  }

  /// A dump format like the `list` mode of the sqlite3 command line tool.
  public struct ListDumpFormat: Sendable {
    public var header: Bool
    public var separator: String
    public var nullValue: String
    private var firstRow = true

    public init(header: Bool = false, separator: String = "|", nullValue: String = "") {
      self.header = header
      self.separator = separator
      self.nullValue = nullValue
    }
  }

  extension ListDumpFormat: DumpFormat {
    public mutating func writeRow(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      if firstRow {
        firstRow = false
        if header {
          stream.writeln(statement.columnNames.joined(separator: separator))
        }
      }
      stream.writeln(
        statement.dumpedColumns.map { plainText($0.value, nullValue: nullValue) }
          .joined(separator: separator)
      )
    }

    public mutating func finalize(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      firstRow = true
    }
  }

  extension DumpFormat where Self == ListDumpFormat {
    /// The list format.
    public static func list(header: Bool = false, separator: String = "|", nullValue: String = "")
      -> Self
    {
      ListDumpFormat(header: header, separator: separator, nullValue: nullValue)
    }
  }

  /// A dump format like the `line` mode of the sqlite3 command line tool.
  public struct LineDumpFormat: Sendable {
    public var nullValue: String
    var firstRow = true

    public init(nullValue: String = "") {
      self.nullValue = nullValue
    }
  }

  extension LineDumpFormat: DumpFormat {
    public mutating func writeRow(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      let lines = statement.dumpedColumns.map {
        (column: $0.name, value: plainText($0.value, nullValue: nullValue))
      }
      if lines.isEmpty { return }
      if firstRow {
        firstRow = false
      } else {
        stream.write("\n")
      }
      let width = lines.map(\.column.count).max()!
      for line in lines {
        stream.write(String(repeating: " ", count: max(0, width - line.column.count)) + line.column)
        stream.write(" = ")
        stream.writeln(line.value)
      }
    }

    public mutating func finalize(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      if !firstRow {
        stream.margin()
      }
      firstRow = true
    }
  }

  extension DumpFormat where Self == LineDumpFormat {
    /// The line format.
    public static func line(nullValue: String = "") -> Self {
      LineDumpFormat(nullValue: nullValue)
    }
  }

  /// A dump format like the `quote` mode of the sqlite3 command line tool.
  public struct QuoteDumpFormat: Sendable {
    public var header: Bool
    public var separator: String
    var firstRow = true

    public init(header: Bool = false, separator: String = ",") {
      self.header = header
      self.separator = separator
    }
  }

  extension QuoteDumpFormat: DumpFormat {
    public mutating func writeRow(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      if firstRow {
        firstRow = false
        if header {
          stream.writeln(
            statement.columnNames.map { db.quotedSQL($0.databaseValue) }
              .joined(separator: separator)
          )
        }
      }
      stream.writeln(
        statement.dumpedColumns.map { db.quotedSQL($0.value) }.joined(separator: separator)
      )
    }

    public mutating func finalize(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      firstRow = true
    }
  }

  extension DumpFormat where Self == QuoteDumpFormat {
    /// The quote format.
    public static func quote(header: Bool = false, separator: String = ",") -> Self {
      QuoteDumpFormat(header: header, separator: separator)
    }
  }

  /// A JSON dump format.
  public struct JSONDumpFormat: Sendable {
    /// The default encoder.
    public static var defaultEncoder: JSONEncoder {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .withoutEscapingSlashes
      encoder.nonConformingFloatEncodingStrategy = .convertToString(
        positiveInfinity: "inf",
        negativeInfinity: "-inf",
        nan: "nan"
      )
      encoder.dataEncodingStrategy = .base64
      return encoder
    }

    public var encoder: JSONEncoder
    var firstRow = true

    public init(encoder: JSONEncoder = JSONDumpFormat.defaultEncoder) {
      self.encoder = encoder
    }
  }

  extension JSONDumpFormat: DumpFormat {
    public mutating func writeRow(_ db: Database, statement: Statement, to stream: inout DumpStream)
      throws
    {
      let pretty = encoder.outputFormatting.contains(.prettyPrinted)
      if firstRow {
        firstRow = false
        stream.write("[")
        if pretty { stream.write("\n") }
      } else {
        stream.write(",\n")
      }
      if pretty { stream.write("  ") }
      stream.write("{")
      var first = true
      for column in statement.dumpedColumns {
        if first {
          first = false
        } else {
          stream.write(",")
        }
        if pretty { stream.write("\n    ") }
        try stream.write(encoded(column.name))
        stream.write(":")
        switch column.value.storage {
        case .null: stream.write("null")
        case .int64(let n): try stream.write(encoded(n))
        case .double(let d): try stream.write(encoded(d))
        case .string(let s): try stream.write(encoded(s))
        case .blob(let data): try stream.write(encoded(data))
        }
      }
      if pretty { stream.write("\n  ") }
      stream.write("}")
    }

    public mutating func finalize(_ db: Database, statement: Statement, to stream: inout DumpStream)
    {
      if firstRow {
        if !statement.columnNames.isEmpty {
          stream.writeln("[]")
        }
      } else {
        if encoder.outputFormatting.contains(.prettyPrinted) {
          stream.write("\n")
        }
        stream.writeln("]")
      }
      firstRow = true
    }

    private func encoded(_ value: some Encodable) throws -> String {
      String(decoding: try encoder.encode(value), as: UTF8.self)
    }
  }

  extension DumpFormat where Self == JSONDumpFormat {
    /// The JSON format.
    public static func json(encoder: JSONEncoder = JSONDumpFormat.defaultEncoder) -> Self {
      JSONDumpFormat(encoder: encoder)
    }
  }

  /// Whether `dumpTables` prints table names.
  public enum DumpTableHeaderOptions: Sendable {
    /// Prints table names when several tables are dumped.
    case automatic
    /// Always prints table names.
    case always
  }

  // MARK: - Dumping

  extension Database {
    /// Prints the results of all statements in the SQL.
    public func dumpSQL(
      _ sql: SQL,
      format: some DumpFormat = .debug(),
      to stream: (any TextOutputStream)? = nil
    ) throws {
      var dumpStream = DumpStream(stream)
      try dumpStatements(allStatements(literal: sql), format: format, to: &dumpStream)
    }

    /// Prints the results of a request, then the rows of its prefetched associations.
    public func dumpRequest(
      _ request: some FetchRequest,
      format: some DumpFormat = .debug(),
      to stream: (any TextOutputStream)? = nil
    ) throws {
      var dumpStream = DumpStream(stream)
      try dumpRequest(request, format: format, to: &dumpStream)
    }

    /// Prints the contents of tables or views.
    public func dumpTables(
      _ tables: [String],
      format: some DumpFormat = .debug(),
      tableHeader: DumpTableHeaderOptions = .automatic,
      stableOrder: Bool = false,
      to stream: (any TextOutputStream)? = nil
    ) throws {
      var dumpStream = DumpStream(stream)
      try dumpTables(
        tables,
        format: format,
        tableHeader: tableHeader,
        stableOrder: stableOrder,
        to: &dumpStream
      )
    }

    /// Prints the schema, then the contents of all tables.
    public func dumpContent(
      format: some DumpFormat = .debug(),
      to stream: (any TextOutputStream)? = nil
    ) throws {
      var dumpStream = DumpStream(stream)
      try dumpSchema(to: &dumpStream)
      dumpStream.margin()
      let tables =
        try String.fetchAll(
          self,
          sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name COLLATE NOCASE"
        )
        .filter { try !ignoresDumpedObject(named: $0) }
      try dumpTables(
        tables,
        format: format,
        tableHeader: .always,
        stableOrder: true,
        to: &dumpStream
      )
    }

    /// Prints the schema.
    public func dumpSchema(to stream: (any TextOutputStream)? = nil) throws {
      var dumpStream = DumpStream(stream)
      try dumpSchema(to: &dumpStream)
    }

    private func dumpStatements<Statements: Cursor>(
      _ statements: Statements,
      format: some DumpFormat,
      to stream: inout DumpStream
    ) throws where Statements.Element == Statement {
      while let statement = try statements.next() {
        var stepFormat = format
        let cursor = try statement.makeCursor(arguments: nil)
        while let row = try cursor.next() {
          statement.dumpedRow = row
          try stepFormat.writeRow(self, statement: statement, to: &stream)
        }
        statement.dumpedRow = nil
        stepFormat.finalize(self, statement: statement, to: &stream)
      }
    }

    private func dumpRequest(
      _ request: some FetchRequest,
      format: some DumpFormat,
      to stream: inout DumpStream
    ) throws {
      let prepared = try request.makePreparedRequest(self, forSingleResult: false)
      try dumpStatements(AnyCursor([prepared.statement]), format: format, to: &stream)
      // Dump the requests of prefetched associations, after the base rows.
      if let supplementaryFetch = prepared.supplementaryFetch {
        let rows = try Row.fetchAllRows(self, request)
        try withoutActuallyEscaping(
          { (request: QueryInterfaceRequest<Row>, keyPath: [String]) in
            stream.write("\n")
            stream.writeln(keyPath.joined(separator: "."))
            try self.dumpRequest(request, format: format, to: &stream)
          },
          do: { willExecute in try supplementaryFetch(self, rows, willExecute) }
        )
      }
    }

    private func dumpTables(
      _ tables: [String],
      format: some DumpFormat,
      tableHeader: DumpTableHeaderOptions,
      stableOrder: Bool,
      to stream: inout DumpStream
    ) throws {
      let header =
        switch tableHeader {
        case .always: true
        case .automatic: tables.count > 1
        }
      for (index, table) in tables.enumerated() {
        if index > 0 { stream.write("\n") }
        if header { stream.writeln(table) }
        if try tableExists(table) {
          try dumpRequest(Table(table).orderByPrimaryKey(), format: format, to: &stream)
        } else if stableOrder {
          try dumpRequest(Table(table).all().withStableOrder(), format: format, to: &stream)
        } else {
          try dumpRequest(Table(table).all(), format: format, to: &stream)
        }
      }
    }

    private func dumpSchema(to stream: inout DumpStream) throws {
      stream.writeln("sqlite_master")
      let rows = try Row.fetchAll(
        self,
        sql: """
          SELECT sql || ';', name
          FROM sqlite_master
          WHERE sql IS NOT NULL
          ORDER BY
            tbl_name COLLATE NOCASE,
            CASE type WHEN 'table' THEN 'a' WHEN 'index' THEN 'aa' ELSE type END,
            name COLLATE NOCASE,
            sql
          """
      )
      for row in rows {
        let name: String = row[1]
        if try ignoresDumpedObject(named: name) { continue }
        stream.writeln(row[0] as String)
      }
    }

    private func ignoresDumpedObject(named name: String) throws -> Bool {
      if Database.isSQLiteInternalTable(name) || Database.isGRDBInternalTable(name) {
        return true
      }
      // Shadow tables of virtual tables, as reported by SQLite 3.37+.
      let type = try? String.fetchOne(
        self,
        sql: "SELECT type FROM pragma_table_list WHERE name = ? AND schema = 'main'",
        arguments: [name]
      )
      return type == "shadow"
    }
  }

  extension DatabaseReader {
    /// Prints the results of all statements in the SQL.
    public func dumpSQL(
      _ sql: SQL,
      format: some DumpFormat = .debug(),
      to stream: (any TextOutputStream)? = nil
    ) throws {
      try unsafeReentrantRead { try $0.dumpSQL(sql, format: format, to: stream) }
    }

    /// Prints the results of a request.
    public func dumpRequest(
      _ request: some FetchRequest,
      format: some DumpFormat = .debug(),
      to stream: (any TextOutputStream)? = nil
    ) throws {
      try unsafeReentrantRead { try $0.dumpRequest(request, format: format, to: stream) }
    }

    /// Prints the contents of tables or views.
    public func dumpTables(
      _ tables: [String],
      format: some DumpFormat = .debug(),
      tableHeader: DumpTableHeaderOptions = .automatic,
      stableOrder: Bool = false,
      to stream: (any TextOutputStream)? = nil
    ) throws {
      try unsafeReentrantRead {
        try $0.dumpTables(
          tables,
          format: format,
          tableHeader: tableHeader,
          stableOrder: stableOrder,
          to: stream
        )
      }
    }

    /// Prints the schema, then the contents of all tables.
    public func dumpContent(
      format: some DumpFormat = .debug(),
      to stream: (any TextOutputStream)? = nil
    ) throws {
      try unsafeReentrantRead { try $0.dumpContent(format: format, to: stream) }
    }

    /// Prints the schema.
    public func dumpSchema(to stream: (any TextOutputStream)? = nil) throws {
      try unsafeReentrantRead { try $0.dumpSchema(to: stream) }
    }
  }
#endif
