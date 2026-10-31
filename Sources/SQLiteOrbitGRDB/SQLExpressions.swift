#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - Assignments

  /// A column assignment in an `UPDATE` statement, such as `score = score + 1`.
  public struct ColumnAssignment: Sendable {
    var columnName: String
    /// nil means "no overwrite" in upserts.
    var value: SQLExpression?

    init(columnName: String, value: SQLExpression?) {
      self.columnName = columnName
      self.value = value
    }

    var column: String { columnName }

    func sql(_ context: SQLGenerationContext) throws -> String? {
      guard let value else { return nil }
      return try quoted(columnName) + " = " + value.sql(context)
    }
  }

  public typealias SQLAssignment = ColumnAssignment

  extension ColumnExpression {
    /// Assigns a value to the column.
    public func set(to value: (any SQLExpressible)?) -> ColumnAssignment {
      ColumnAssignment(columnName: name, value: value?.sqlExpression ?? .null)
    }

    /// An upsert assignment that does not overwrite the column.
    public var noOverwrite: ColumnAssignment {
      ColumnAssignment(columnName: name, value: nil)
    }
  }

  // MARK: - Comparison operators

  extension SQLSpecificExpressible {
    public static func == (lhs: Self, rhs: (any SQLExpressible)?) -> SQLExpression {
      .equal(lhs.sqlExpression, rhs?.sqlExpression ?? .null)
    }

    public static func == (lhs: Self, rhs: Bool) -> SQLExpression {
      lhs.sqlExpression.is(rhs ? .true : .false)
    }

    public static func == (lhs: (any SQLExpressible)?, rhs: Self) -> SQLExpression {
      .equal(lhs?.sqlExpression ?? .null, rhs.sqlExpression)
    }

    public static func == (lhs: Bool, rhs: Self) -> SQLExpression {
      rhs.sqlExpression.is(lhs ? .true : .false)
    }

    public static func == (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .equal(lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func != (lhs: Self, rhs: (any SQLExpressible)?) -> SQLExpression {
      !(lhs == rhs)
    }

    public static func != (lhs: Self, rhs: Bool) -> SQLExpression {
      !(lhs == rhs)
    }

    public static func != (lhs: (any SQLExpressible)?, rhs: Self) -> SQLExpression {
      !(lhs == rhs)
    }

    public static func != (lhs: Bool, rhs: Self) -> SQLExpression {
      !(lhs == rhs)
    }

    public static func != (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      !(lhs == rhs)
    }

    public static func === (lhs: Self, rhs: (any SQLExpressible)?) -> SQLExpression {
      .compare(.is, lhs.sqlExpression, rhs?.sqlExpression ?? .null)
    }

    public static func === (lhs: (any SQLExpressible)?, rhs: Self) -> SQLExpression {
      if let lhs { return .compare(.is, lhs.sqlExpression, rhs.sqlExpression) }
      return .compare(.is, rhs.sqlExpression, .null)
    }

    public static func === (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .compare(.is, lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func !== (lhs: Self, rhs: (any SQLExpressible)?) -> SQLExpression {
      !(lhs === rhs)
    }

    public static func !== (lhs: (any SQLExpressible)?, rhs: Self) -> SQLExpression {
      !(lhs === rhs)
    }

    public static func !== (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      !(lhs === rhs)
    }

    public static func < (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .binary("<", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func < (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .binary("<", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func < (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .binary("<", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func <= (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .binary("<=", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func <= (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .binary("<=", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func <= (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .binary("<=", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func > (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .binary(">", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func > (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .binary(">", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func > (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .binary(">", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func >= (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .binary(">=", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func >= (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .binary(">=", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func >= (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .binary(">=", lhs.sqlExpression, rhs.sqlExpression)
    }
  }

  // MARK: - Inclusion

  extension Range where Bound: SQLExpressible {
    public func contains(_ element: some SQLSpecificExpressible) -> SQLExpression {
      (element >= lowerBound) && (element < upperBound)
    }
  }

  extension ClosedRange where Bound: SQLExpressible {
    public func contains(_ element: some SQLSpecificExpressible) -> SQLExpression {
      .between(element.sqlExpression, lowerBound.sqlExpression, upperBound.sqlExpression)
    }
  }

  extension Sequence where Element: SQLExpressible {
    public func contains(_ element: some SQLSpecificExpressible) -> SQLExpression {
      SQLCollection.array(map(\.sqlExpression)).contains(element.sqlExpression)
    }
  }

  extension Sequence where Element == any SQLExpressible {
    public func contains(_ element: some SQLSpecificExpressible) -> SQLExpression {
      SQLCollection.array(map(\.sqlExpression)).contains(element.sqlExpression)
    }
  }

  // MARK: - Arithmetic and logical operators

  extension SQLSpecificExpressible {
    public static func * (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .associative(.multiply, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func * (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .associative(.multiply, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func * (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .associative(.multiply, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func / (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .binary("/", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func / (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .binary("/", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func / (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .binary("/", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func + (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .associative(.add, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func + (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .associative(.add, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func + (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .associative(.add, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static prefix func - (value: Self) -> SQLExpression {
      .unary("-", value.sqlExpression)
    }

    public static func - (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .binary("-", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func - (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .binary("-", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func - (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .binary("-", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func && (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .associative(.and, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func && (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .associative(.and, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func && (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .associative(.and, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func || (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .associative(.or, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func || (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .associative(.or, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func || (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .associative(.or, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static prefix func ! (value: Self) -> SQLExpression {
      value.sqlExpression.is(.falsey)
    }

    public static func & (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .associative(.bitwiseAnd, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func & (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .associative(.bitwiseAnd, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func & (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .associative(.bitwiseAnd, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func | (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .associative(.bitwiseOr, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func | (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .associative(.bitwiseOr, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func | (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .associative(.bitwiseOr, [lhs.sqlExpression, rhs.sqlExpression])
    }

    public static func << (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .binary("<<", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func << (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .binary("<<", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func << (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .binary("<<", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func >> (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .binary(">>", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func >> (lhs: some SQLExpressible, rhs: Self) -> SQLExpression {
      .binary(">>", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static func >> (lhs: Self, rhs: some SQLSpecificExpressible) -> SQLExpression {
      .binary(">>", lhs.sqlExpression, rhs.sqlExpression)
    }

    public static prefix func ~ (value: Self) -> SQLExpression {
      .unary("~", value.sqlExpression)
    }

    /// The `LIKE` operator.
    public func like(_ pattern: some SQLExpressible, escape: (any SQLExpressible)? = nil)
      -> SQLExpression
    {
      SQLExpression(
        node: .like(
          sqlExpression,
          pattern.sqlExpression,
          escape: escape?.sqlExpression,
          negated: false
        )
      )
    }
  }

  extension SQLExpressible {
    /// Applies a collation by name.
    public func collating(_ collation: String) -> SQLExpression {
      .collated(sqlExpression, collation)
    }
  }

  // MARK: - Functions

  extension Database {
    /// An SQLite storage class, for `CAST` expressions.
    public struct StorageClass: RawRepresentable, Hashable, Sendable {
      public let rawValue: String

      public init(rawValue: String) {
        self.rawValue = rawValue
      }

      public static let integer = StorageClass(rawValue: "INTEGER")
      public static let real = StorageClass(rawValue: "REAL")
      public static let text = StorageClass(rawValue: "TEXT")
      public static let blob = StorageClass(rawValue: "BLOB")
      public static let numeric = StorageClass(rawValue: "NUMERIC")
    }
  }

  public func abs(_ value: some SQLSpecificExpressible) -> SQLExpression {
    .function("ABS", [value.sqlExpression])
  }

  public func average(_ value: some SQLSpecificExpressible) -> SQLExpression {
    .aggregate("AVG", [value.sqlExpression])
  }

  public func average(_ value: some SQLSpecificExpressible, filter: some SQLSpecificExpressible)
    -> SQLExpression
  {
    .aggregate("AVG", [value.sqlExpression], filter: filter.sqlExpression)
  }

  public func cast(
    _ expression: some SQLSpecificExpressible,
    as storageClass: Database.StorageClass
  )
    -> SQLExpression
  {
    .cast(expression.sqlExpression, as: storageClass.rawValue)
  }

  public func coalesce(_ values: some Collection<any SQLSpecificExpressible>) -> SQLExpression {
    guard let first = values.first else { return .null }
    return values.count > 1
      ? .function("COALESCE", values.map(\.sqlExpression)) : first.sqlExpression
  }

  public func count(_ counted: some SQLSpecificExpressible) -> SQLExpression {
    .function("COUNT", [counted.sqlExpression])
  }

  public func count(distinct value: some SQLSpecificExpressible) -> SQLExpression {
    .aggregate("COUNT", [value.sqlExpression], distinct: true)
  }

  extension SQLSpecificExpressible {
    public static func ?? (lhs: Self, rhs: some SQLExpressible) -> SQLExpression {
      .function("IFNULL", [lhs.sqlExpression, rhs.sqlExpression])
    }
  }

  public func length(_ value: some SQLSpecificExpressible) -> SQLExpression {
    .function("LENGTH", [value.sqlExpression])
  }

  public func max(
    _ value1: any SQLSpecificExpressible,
    _ value2: any SQLExpressible,
    _ values: any SQLExpressible...
  ) -> SQLExpression {
    .function("MAX", [value1.sqlExpression, value2.sqlExpression] + values.map(\.sqlExpression))
  }

  public func max(_ value: some SQLSpecificExpressible) -> SQLExpression {
    .aggregate("MAX", [value.sqlExpression])
  }

  public func max(_ value: some SQLSpecificExpressible, filter: some SQLSpecificExpressible)
    -> SQLExpression
  {
    .aggregate("MAX", [value.sqlExpression], filter: filter.sqlExpression)
  }

  public func min(
    _ value1: any SQLSpecificExpressible,
    _ value2: any SQLExpressible,
    _ values: any SQLExpressible...
  ) -> SQLExpression {
    .function("MIN", [value1.sqlExpression, value2.sqlExpression] + values.map(\.sqlExpression))
  }

  public func min(_ value: some SQLSpecificExpressible) -> SQLExpression {
    .aggregate("MIN", [value.sqlExpression])
  }

  public func min(_ value: some SQLSpecificExpressible, filter: some SQLSpecificExpressible)
    -> SQLExpression
  {
    .aggregate("MIN", [value.sqlExpression], filter: filter.sqlExpression)
  }

  public func sum(_ value: some SQLSpecificExpressible) -> SQLExpression {
    .aggregate("SUM", [value.sqlExpression])
  }

  public func sum(_ value: some SQLSpecificExpressible, filter: some SQLSpecificExpressible)
    -> SQLExpression
  {
    .aggregate("SUM", [value.sqlExpression], filter: filter.sqlExpression)
  }

  public func total(_ value: some SQLSpecificExpressible) -> SQLExpression {
    .aggregate("TOTAL", [value.sqlExpression])
  }

  public func total(_ value: some SQLSpecificExpressible, filter: some SQLSpecificExpressible)
    -> SQLExpression
  {
    .aggregate("TOTAL", [value.sqlExpression], filter: filter.sqlExpression)
  }

  extension SQLSpecificExpressible {
    /// Capitalizes text with Swift's `capitalized` (requires the GRDB standard functions).
    public var capitalized: SQLExpression {
      .function("swiftCapitalizedString", [sqlExpression], isPure: true)
    }

    /// Lowercases text with Swift's `lowercased()`.
    public var lowercased: SQLExpression {
      .function("swiftLowercaseString", [sqlExpression], isPure: true)
    }

    /// Uppercases text with Swift's `uppercased()`.
    public var uppercased: SQLExpression {
      .function("swiftUppercaseString", [sqlExpression], isPure: true)
    }

    /// Capitalizes text with Swift's `localizedCapitalized`.
    public var localizedCapitalized: SQLExpression {
      .function("swiftLocalizedCapitalizedString", [sqlExpression], isPure: true)
    }

    /// Lowercases text with Swift's `localizedLowercase`.
    public var localizedLowercased: SQLExpression {
      .function("swiftLocalizedLowercaseString", [sqlExpression], isPure: true)
    }

    /// Uppercases text with Swift's `localizedUppercase`.
    public var localizedUppercased: SQLExpression {
      .function("swiftLocalizedUppercaseString", [sqlExpression], isPure: true)
    }
  }

  /// A modifier for SQLite date functions.
  public enum SQLDateModifier: SQLSpecificExpressible, Sendable {
    case second(Double)
    case minute(Int)
    case hour(Int)
    case day(Int)
    case month(Int)
    case year(Int)
    case startOfDay
    case startOfMonth
    case startOfYear
    case weekday(Int)
    case unixEpoch
    case localTime
    case utc

    public var sqlExpression: SQLExpression {
      rawValue.sqlExpression
    }

    var rawValue: String {
      switch self {
      case .day(let value): return "\(value) days"
      case .hour(let value): return "\(value) hours"
      case .minute(let value): return "\(value) minutes"
      case .second(let value): return "\(value) seconds"
      case .month(let value): return "\(value) months"
      case .year(let value): return "\(value) years"
      case .startOfMonth: return "start of month"
      case .startOfYear: return "start of year"
      case .startOfDay: return "start of day"
      case .weekday(let value): return "weekday \(value)"
      case .unixEpoch: return "unixepoch"
      case .localTime: return "localtime"
      case .utc: return "utc"
      }
    }
  }

  public func julianDay(_ value: some SQLSpecificExpressible, _ modifiers: SQLDateModifier...)
    -> SQLExpression
  {
    .function("JULIANDAY", [value.sqlExpression] + modifiers.map(\.sqlExpression))
  }

  public func dateTime(_ value: some SQLSpecificExpressible, _ modifiers: SQLDateModifier...)
    -> SQLExpression
  {
    .function("DATETIME", [value.sqlExpression] + modifiers.map(\.sqlExpression))
  }

  extension SQL: SQLSpecificExpressible {
    public var sqlExpression: SQLExpression { .literal(self) }
    public var sqlSelection: SQLSelection { .literal(self) }
    public var sqlOrdering: SQLOrdering { .literal(self) }
  }
#endif
