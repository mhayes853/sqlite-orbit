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
    public init(arrayLiteral elements: (any DatabaseValueConvertible)?...) { self.init(elements) }
    public init(dictionaryLiteral elements: (String, (any DatabaseValueConvertible)?)...) {
      self.init(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }
    public mutating func append(contentsOf arguments: Self) -> [String: DatabaseValue] {
      values.append(contentsOf: arguments.values)
      var replaced: [String: DatabaseValue] = [:]
      for (key, value) in arguments.namedValues {
        if let old = namedValues.updateValue(value, forKey: key) { replaced[key] = old }
      }
      return replaced
    }
    mutating func consume(_ count: Int) { values.removeFirst(count) }
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
    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
  }

  public struct SQL: Sendable, ExpressibleByStringInterpolation {
    public var sql: String
    public var arguments: StatementArguments
    public init(sql: String, arguments: StatementArguments = StatementArguments()) {
      self.sql = sql
      self.arguments = arguments
    }
    public init(stringLiteral value: String) { self.init(sql: value) }
    public init(stringInterpolation: StringInterpolation) {
      self.init(
        sql: stringInterpolation.sql,
        arguments: StatementArguments(stringInterpolation.values)
      )
    }
    public struct StringInterpolation: StringInterpolationProtocol {
      var sql = ""
      var values: [DatabaseValue] = []
      public init(literalCapacity: Int, interpolationCount: Int) {
        sql.reserveCapacity(literalCapacity)
      }
      public mutating func appendLiteral(_ literal: String) { sql += literal }
      public mutating func appendInterpolation(_ value: (any DatabaseValueConvertible)?) {
        sql += "?"
        values.append(value?.databaseValue ?? .null)
      }
      public mutating func appendInterpolation(sql text: String) { sql += text }
      public mutating func appendInterpolation(_ literal: SQL) {
        precondition(literal.arguments.namedValues.isEmpty)
        sql += literal.sql
        values += literal.arguments.values
      }
      public mutating func appendInterpolation(_ expression: some SQLExpressible) {
        appendInterpolation(expression.sqlExpression.literal)
      }
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
      .init(sql: lhs.sql + rhs.sql, arguments: lhs.arguments + rhs.arguments)
    }
  }

  // Resolve SQLite parameter slots without changing the SQL text (and therefore result column
  // names). Quoted text, identifiers, comments, repeated names, and numbered slots follow SQLite.
  func bindArguments(
    _ arguments: StatementArguments,
    sql: String,
    allowRemaining: Bool = false,
    allowMissing: Bool = false
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
            if i < bytes.count && bytes[i] == end && b != 91 { i += 1 } else { break }
          }
        }
      } else if b == 45 && i + 1 < bytes.count && bytes[i + 1] == 45 {
        while i < bytes.count && bytes[i] != 10 { i += 1 }
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
            while i < bytes.count && identifier(bytes[i]) { i += 1 }
          }
          if i < bytes.count && bytes[i] == 40 {
            i += 1
            while i < bytes.count && bytes[i] != 41 { i += 1 }
            if i < bytes.count { i += 1 }
          }
        }
        let token = String(decoding: bytes[start..<i], as: UTF8.self)
        if b != 63 && i == start + 1 { continue }
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
          if b != 63 { slots[token] = slot }
        }
        if token.count > 1 && names[slot] == nil { names[slot] = String(token.dropFirst()) }
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
