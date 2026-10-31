#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public struct StatementArguments: Equatable, Sendable, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
  {
    public private(set) var values: [DatabaseValue]
    public private(set) var namedValues: [String: DatabaseValue]

    public init() {
      values = []
      namedValues = [:]
    }

    public init(_ values: [(any DatabaseValueConvertible)?]) {
      self.values = values.map { $0?.databaseValue ?? .null }
      namedValues = [:]
    }

    public init<S: Sequence>(_ values: S) where S.Element: DatabaseValueConvertible {
      self.values = values.map(\.databaseValue)
      namedValues = [:]
    }

    public init(_ values: [String: (any DatabaseValueConvertible)?]) {
      self.values = []
      namedValues = values.mapValues { $0?.databaseValue ?? .null }
    }

    public init(arrayLiteral elements: (any DatabaseValueConvertible)?...) {
      self.init(elements)
    }

    public init(dictionaryLiteral elements: (String, (any DatabaseValueConvertible)?)...) {
      self.init(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }

    public mutating func append(contentsOf arguments: Self) -> [String: DatabaseValue] {
      values.append(contentsOf: arguments.values)
      var replaced: [String: DatabaseValue] = [:]
      for (key, value) in arguments.namedValues {
        if let old = namedValues.updateValue(value, forKey: key) {
          replaced[key] = old
        }
      }
      return replaced
    }

    mutating func consume(_ count: Int) {
      values.removeFirst(count)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
      precondition(
        Set(lhs.namedValues.keys).isDisjoint(with: rhs.namedValues.keys),
        "duplicate named arguments"
      )
      var result = lhs
      _ = result.append(contentsOf: rhs)
      return result
    }

    public static func &+ (lhs: Self, rhs: Self) -> Self {
      var result = lhs
      _ = result.append(contentsOf: rhs)
      return result
    }

    public static func += (lhs: inout Self, rhs: Self) {
      lhs = lhs + rhs
    }
  }

  /// An SQL literal: raw SQL text and arguments mixed with query-interface components.
  ///
  /// Components such as expressions and subqueries are rendered when the literal is built
  /// for a database, so that they can be qualified with table aliases and resolve schema
  /// information.
  public struct SQL: Sendable, ExpressibleByStringInterpolation {
    enum Element: Sendable {
      case sql(String, StatementArguments)
      case expression(SQLExpression)
      case selection(SQLSelection)
      case ordering(SQLOrdering)
      case subquery(SQLSubquery)

      var isEmpty: Bool {
        if case .sql(let text, _) = self { return text.isEmpty }
        return false
      }

      func sql(_ context: SQLGenerationContext) throws -> String {
        switch self {
        case .sql(let text, let arguments):
          try context.appendLiteralArguments(arguments)
          return text
        case .expression(let expression):
          return try expression.sql(context)
        case .selection(let selection):
          return try selection.sql(context)
        case .ordering(let ordering):
          return try ordering.sql(context)
        case .subquery(let subquery):
          return try subquery.sql(context)
        }
      }

      func qualified(with alias: TableAliasBase) -> Element {
        switch self {
        case .sql, .subquery: return self
        case .expression(let expression): return .expression(expression.qualified(with: alias))
        case .selection(let selection): return .selection(selection.qualified(with: alias))
        case .ordering(let ordering): return .ordering(ordering.qualified(with: alias))
        }
      }
    }

    private(set) var elements: [Element]

    init(elements: [Element]) {
      self.elements = elements
    }

    public init(sql: String, arguments: StatementArguments = StatementArguments()) {
      self.init(elements: [.sql(sql, arguments)])
    }

    public init(_ expression: some SQLSpecificExpressible) {
      self.init(elements: [.expression(expression.sqlExpression)])
    }

    public init(stringLiteral value: String) {
      self.init(sql: value)
    }

    public init(stringInterpolation: SQLInterpolation) {
      self.init(elements: stringInterpolation.elements)
    }

    public typealias StringInterpolation = SQLInterpolation

    /// The SQL text, rendered without a database connection.
    ///
    /// Components that need schema information (such as subqueries that select primary
    /// keys) require `build(_:)` instead.
    public var sql: String {
      contextFreeBuild().sql
    }

    /// The arguments of the SQL text, rendered without a database connection.
    public var arguments: StatementArguments {
      contextFreeBuild().arguments
    }

    public var isEmpty: Bool {
      elements.allSatisfy(\.isEmpty)
    }

    /// Returns the SQL text and arguments of the literal.
    public func build(_ db: Database) throws -> (sql: String, arguments: StatementArguments) {
      let context = SQLGenerationContext(db)
      let sql = try self.sql(context)
      return (sql, context.arguments)
    }

    func contextFreeBuild() -> (sql: String, arguments: StatementArguments) {
      let context = SQLGenerationContext(nil)
      do {
        let sql = try self.sql(context)
        return (sql, context.arguments)
      } catch {
        preconditionFailure("SQL literal requires a database connection: \(error)")
      }
    }

    func sql(_ context: SQLGenerationContext) throws -> String {
      try elements.map { try $0.sql(context) }.joined()
    }

    func qualified(with alias: TableAliasBase) -> SQL {
      SQL(elements: elements.map { $0.qualified(with: alias) })
    }

    public mutating func append(literal: SQL) {
      elements += literal.elements
    }

    public mutating func append(sql: String, arguments: StatementArguments = StatementArguments()) {
      append(literal: SQL(sql: sql, arguments: arguments))
    }

    public static func += (lhs: inout Self, rhs: Self) {
      lhs.append(literal: rhs)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
      SQL(elements: lhs.elements + rhs.elements)
    }
  }

  /// The string interpolation of SQL literals.
  public struct SQLInterpolation: StringInterpolationProtocol, Sendable {
    var elements: [SQL.Element] = []

    public init(literalCapacity: Int, interpolationCount: Int) {
      elements.reserveCapacity(interpolationCount * 2 + 1)
    }

    public mutating func appendLiteral(_ literal: String) {
      if literal.isEmpty { return }
      elements.append(.sql(literal, StatementArguments()))
    }

    public mutating func appendInterpolation(
      sql text: String,
      arguments: StatementArguments = StatementArguments()
    ) {
      elements.append(.sql(text, arguments))
    }

    public mutating func appendInterpolation(_ literal: SQL) {
      elements += literal.elements
    }

    public mutating func appendInterpolation(literal: SQL) {
      elements += literal.elements
    }

    public mutating func appendInterpolation(identifier: String) {
      appendLiteral(quoted(identifier))
    }

    public mutating func appendInterpolation<S: StringProtocol>(_ string: S) {
      elements.append(.expression(String(string).sqlExpression))
    }

    public mutating func appendInterpolation(_ table: (some TableRecord).Type) {
      appendLiteral(quoted(table.databaseTableName))
    }

    @_disfavoredOverload
    public mutating func appendInterpolation(_ table: any TableRecord.Type) {
      appendLiteral(quoted(table.databaseTableName))
    }

    @_disfavoredOverload
    public mutating func appendInterpolation<T>(_ table: Table<T>) {
      appendLiteral(quoted(table.tableName))
    }

    public mutating func appendInterpolation(tableOf record: some TableRecord) {
      appendInterpolation(type(of: record))
    }

    @_disfavoredOverload
    public mutating func appendInterpolation(tableOf record: any TableRecord) {
      appendInterpolation(type(of: record))
    }

    public mutating func appendInterpolation(
      columnsOf recordType: (some TableRecord).Type,
      tableAlias: String? = nil
    ) {
      let alias = TableAliasBase(
        tableName: recordType.databaseTableName,
        userName: tableAlias ?? recordType.databaseTableName
      )
      for (index, selection) in recordType.databaseSelection.enumerated() {
        if index > 0 { appendLiteral(", ") }
        elements.append(.selection(selection.sqlSelection.qualified(with: alias)))
      }
    }

    public mutating func appendInterpolation(_ selection: some SQLSelectable) {
      elements.append(.selection(selection.sqlSelection))
    }

    @_disfavoredOverload
    public mutating func appendInterpolation(_ selection: (any SQLSelectable)?) {
      if let selection {
        elements.append(.selection(selection.sqlSelection))
      } else {
        appendLiteral("NULL")
      }
    }

    public mutating func appendInterpolation(_ ordering: some SQLOrderingTerm) {
      elements.append(.ordering(ordering.sqlOrdering))
    }

    @_disfavoredOverload
    public mutating func appendInterpolation(_ ordering: any SQLOrderingTerm) {
      elements.append(.ordering(ordering.sqlOrdering))
    }

    public mutating func appendInterpolation(
      _ expressible: some SQLExpressible & SQLSelectable & SQLOrderingTerm
    ) {
      elements.append(.expression(expressible.sqlExpression))
    }

    @_disfavoredOverload
    public mutating func appendInterpolation(_ expressible: (any SQLExpressible)?) {
      if let expressible {
        elements.append(.expression(expressible.sqlExpression))
      } else {
        appendLiteral("NULL")
      }
    }

    public mutating func appendInterpolation(_ key: some CodingKey) {
      appendInterpolation(Column(key.stringValue))
    }

    public mutating func appendInterpolation(
      _ key: some CodingKey & SQLExpressible & SQLSelectable & SQLOrderingTerm
    ) {
      appendInterpolation(Column(key.stringValue))
    }

    @_disfavoredOverload
    public mutating func appendInterpolation(_ key: any CodingKey) {
      appendInterpolation(Column(key.stringValue))
    }

    public mutating func appendInterpolation(
      _ subquery: some SQLSubqueryable & SQLExpressible & SQLSelectable & SQLOrderingTerm
    ) {
      elements.append(.subquery(subquery.sqlSubquery))
    }

    public mutating func appendInterpolation(_ sequence: some Sequence<some SQLExpressible>) {
      appendExpressions(sequence.map(\.sqlExpression))
    }

    public mutating func appendInterpolation(_ sequence: some Sequence<any SQLExpressible>) {
      appendExpressions(sequence.map(\.sqlExpression))
    }

    public mutating func appendInterpolation<S>(_ expressible: S)
    where S: SQLExpressible, S: Sequence, S.Element: SQLExpressible {
      elements.append(.expression(expressible.sqlExpression))
    }

    public mutating func appendInterpolation(_ collation: DatabaseCollation) {
      appendLiteral(collation.name)
    }

    public mutating func appendInterpolation(_ collation: Database.CollationName) {
      appendLiteral(collation.rawValue)
    }

    private mutating func appendExpressions(_ expressions: [SQLExpression]) {
      if expressions.isEmpty {
        appendLiteral("(SELECT NULL WHERE NULL)")
        return
      }
      appendLiteral("(")
      for (index, expression) in expressions.enumerated() {
        if index > 0 { appendLiteral(",") }
        elements.append(.expression(expression))
      }
      appendLiteral(")")
    }
  }

  extension SQL {
    // Schema statements cannot bind parameters. Reuse the SQL tokenizer so question marks in
    // strings, identifiers, and comments remain untouched; let the selected engine quote values.
    func expandedSQL(in db: Database) throws -> String {
      let (sql, arguments) = try build(db)
      var parameters: [(Range<Int>, Int)] = []
      let values = try bindArguments(
        arguments,
        sql: sql,
        parameter: { parameters.append(($0, $1)) }
      )
      .values
      guard !parameters.isEmpty else {
        return sql
      }
      let literals = try values.map { try db.quotedLiteral($0) }
      var bytes = Array(sql.utf8)
      for (range, slot) in parameters.reversed() {
        bytes.replaceSubrange(range, with: literals[slot].utf8)
      }
      return String(decoding: bytes, as: UTF8.self)
    }
  }

  extension Sequence where Element == SQL {
    public func joined(separator: String = "") -> SQL {
      SQLiteOrbitGRDB.joined(Array(self), separator: separator)
    }
  }

  func joined(_ fragments: [SQL], separator: String) -> SQL {
    var elements: [SQL.Element] = []
    for (index, fragment) in fragments.enumerated() {
      if index > 0 && !separator.isEmpty {
        elements.append(.sql(separator, StatementArguments()))
      }
      elements += fragment.elements
    }
    return SQL(elements: elements)
  }

  // Resolve SQLite parameter slots without changing the SQL text (and therefore result column
  // names). Quoted text, identifiers, comments, repeated names, and numbered slots follow SQLite.
  func bindArguments(
    _ arguments: StatementArguments,
    sql: String,
    allowRemaining: Bool = false,
    allowMissing: Bool = false,
    parameter: ((Range<Int>, Int) -> Void)? = nil
  ) throws -> (values: [DatabaseValue], consumed: Int) {
    let bytes = Array(sql.utf8)
    var i = 0
    var highest = 0
    var consumed = 0
    var slots: [String: Int] = [:]
    var names: [Int: String] = [:]

    func identifier(_ b: UInt8) -> Bool {
      b >= 128 || b == 95 || (48...57).contains(b) || (65...90).contains(b)
        || (97...122).contains(b)
    }
    while i < bytes.count {
      let b = bytes[i]
      if b == 39 || b == 34 || b == 96 || b == 91 {
        let end: UInt8 = b == 91 ? 93 : b
        i += 1
        while i < bytes.count {
          let c = bytes[i]
          i += 1
          if c == end {
            if i < bytes.count && bytes[i] == end && b != 91 {
              i += 1
            } else {
              break
            }
          }
        }
      } else if b == 45 && i + 1 < bytes.count && bytes[i + 1] == 45 {
        while i < bytes.count && bytes[i] != 10 {
          i += 1
        }
      } else if b == 47 && i + 1 < bytes.count && bytes[i + 1] == 42 {
        i += 2
        while i < bytes.count {
          if bytes[i] == 42 && i + 1 < bytes.count && bytes[i + 1] == 47 {
            i += 2
            break
          }
          i += 1
        }
      } else if b == 63 || b == 58 || b == 64 || b == 36 {
        let start = i
        i += 1
        while i < bytes.count && (b == 63 ? (48...57).contains(bytes[i]) : identifier(bytes[i])) {
          i += 1
        }
        if b == 36 {
          while i + 1 < bytes.count && bytes[i] == 58 && bytes[i + 1] == 58 {
            i += 2
            while i < bytes.count && identifier(bytes[i]) {
              i += 1
            }
          }
          if i < bytes.count && bytes[i] == 40 {
            i += 1
            while i < bytes.count && bytes[i] != 41 {
              i += 1
            }
            if i < bytes.count {
              i += 1
            }
          }
        }
        let token = String(decoding: bytes[start..<i], as: UTF8.self)
        if b != 63 && i == start + 1 {
          continue
        }
        let slot: Int
        if b == 63 && token.count > 1 {
          guard let number = Int(token.dropFirst()), number > 0, number <= 32766 else {
            throw DatabaseError(
              resultCode: .SQLITE_MISUSE,
              message: "invalid parameter index",
              sql: sql
            )
          }
          slot = number
          highest = max(highest, number)
        } else if b != 63, let existing = slots[token] {
          slot = existing
        } else {
          highest += 1
          slot = highest
          if b != 63 {
            slots[token] = slot
          }
        }
        parameter?(start..<i, slot - 1)
        if token.count > 1 && names[slot] == nil {
          names[slot] = String(token.dropFirst())
        }
      } else {
        i += 1
      }
    }
    var bindings: [DatabaseValue] = []
    for slot in 1..<(highest + 1) {
      if let name = names[slot], let value = arguments.namedValues[name] {
        bindings.append(value)
      } else if consumed < arguments.values.count {
        bindings.append(arguments.values[consumed])
        consumed += 1
      } else if allowMissing {
        bindings.append(.null)
      } else {
        throw DatabaseError(
          resultCode: .SQLITE_MISUSE,
          message: "missing statement argument",
          sql: sql,
          arguments: arguments
        )
      }
    }
    guard allowRemaining || consumed == arguments.values.count else {
      throw DatabaseError(
        resultCode: .SQLITE_MISUSE,
        message: "unused statement arguments",
        sql: sql,
        arguments: arguments
      )
    }
    return (bindings, consumed)
  }

  func quoted(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

#endif
