#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - JSON expressions

  /// An SQL expression that is interpreted as a JSON value.
  public protocol SQLJSONExpressible: SQLSpecificExpressible {}

  extension ColumnExpression where Self: SQLJSONExpressible {
    public var sqlExpression: SQLExpression {
      var result = SQLExpression.column(name)
      result.prefersJSON = true
      return result
    }
  }

  /// A column that contains JSON.
  public struct JSONColumn: ColumnExpression, SQLJSONExpressible, Sendable {
    public var name: String

    public init(_ name: String) {
      self.name = name
    }

    public init(_ codingKey: some CodingKey) {
      name = codingKey.stringValue
    }
  }

  /// A type-erased JSON expression.
  public struct AnySQLJSONExpressible: SQLJSONExpressible {
    public let sqlExpression: SQLExpression

    public init(_ base: some SQLJSONExpressible) {
      self.init(sqlExpression: base.sqlExpression)
    }

    init(sqlExpression: SQLExpression) {
      var expression = sqlExpression
      expression.prefersJSON = true
      self.sqlExpression = expression
    }
  }

  extension SQLSpecificExpressible {
    /// The expression, interpreted as JSON.
    public var asJSON: AnySQLJSONExpressible {
      AnySQLJSONExpressible(sqlExpression: sqlExpression)
    }
  }

  extension SQLJSONExpressible {
    /// The SQL value at a JSON path: `expression ->> path`.
    public subscript(_ path: some SQLExpressible) -> SQLExpression {
      .binary("->>", sqlExpression, path.sqlExpression)
    }

    /// `JSON_EXTRACT(expression, path)`.
    public func jsonExtract(atPath path: some SQLExpressible) -> SQLExpression {
      Database.jsonExtract(self, atPath: path)
    }

    /// `JSON_EXTRACT(expression, paths...)`.
    public func jsonExtract(atPaths paths: some Collection<some SQLExpressible>) -> SQLExpression {
      Database.jsonExtract(self, atPaths: paths)
    }

    /// The JSON representation at a JSON path: `expression -> path`.
    public func jsonRepresentation(atPath path: some SQLExpressible) -> SQLExpression {
      .binary("->", sqlExpression, path.sqlExpression)
    }
  }

  extension TableAliasBase {
    /// Qualifies a JSON expression with this alias.
    public subscript(
      _ expression: some SQLJSONExpressible & SQLSpecificExpressible & SQLSelectable
        & SQLOrderingTerm
    ) -> AnySQLJSONExpressible {
      AnySQLJSONExpressible(sqlExpression: expression.sqlExpression.qualified(with: self))
    }
  }

  extension SQLExpression {
    private static let jsonFunctions: Set<String> = [
      "JSON", "JSON_ARRAY", "JSON_GROUP_ARRAY", "JSON_GROUP_OBJECT", "JSON_INSERT", "JSON_OBJECT",
      "JSON_PATCH", "JSON_REMOVE", "JSON_REPLACE", "JSON_SET", "JSON_QUOTE", "JSONB",
      "JSONB_ARRAY", "JSONB_GROUP_ARRAY", "JSONB_GROUP_OBJECT", "JSONB_INSERT", "JSONB_OBJECT",
      "JSONB_PATCH", "JSONB_REMOVE", "JSONB_REPLACE", "JSONB_SET"
    ]

    /// Whether the expression produces a JSON value.
    var isJSONValue: Bool {
      switch node {
      case .value(let value): return value.isNull
      case .binary(let op, _, _): return op == "->"
      case .collated(let e, _): return e.isJSONValue
      case .function(let name, let arguments, _):
        let upper = name.uppercased()
        return Self.jsonFunctions.contains(upper)
          || (upper == "JSON_EXTRACT" && arguments.count > 2)
      case .aggregate(let invocation):
        return Self.jsonFunctions.contains(invocation.name.uppercased())
      default: return false
      }
    }

    /// The expression as an argument of JSON builder functions: JSON values that are not
    /// already JSON are wrapped in `JSON()` (or `JSONB()` on SQLite 3.45+).
    var jsonBuilderExpression: SQLExpression {
      guard prefersJSON, !isJSONValue else { return self }
      return .function(builtInSQLiteVersionNumber >= 3_045_000 ? "JSONB" : "JSON", [self])
    }
  }

  // MARK: - JSON functions

  extension Database {
    /// Options for `jsonIsValid`.
    public struct JSONValidationOptions: OptionSet, Sendable {
      public let rawValue: Int

      public init(rawValue: Int) {
        self.rawValue = rawValue
      }

      public static let json = JSONValidationOptions(rawValue: 1)
      public static let json5 = JSONValidationOptions(rawValue: 2)
      public static let probablyJSONB = JSONValidationOptions(rawValue: 4)
      public static let jsonb = JSONValidationOptions(rawValue: 8)
    }

    private static func call(_ name: String, _ arguments: [SQLExpression]) -> SQLExpression {
      .function(name, arguments)
    }

    private static func assignments(
      _ value: some SQLExpressible,
      _ assignments: some Collection<(key: String, value: any SQLExpressible)>
    ) -> [SQLExpression] {
      [value.sqlExpression]
        + assignments.flatMap {
          [$0.key.sqlExpression, $0.value.sqlExpression.jsonBuilderExpression]
        }
    }

    private static func objectElements(
      _ elements: some Collection<(key: String, value: any SQLExpressible)>
    ) -> [SQLExpression] {
      elements.flatMap { [$0.key.sqlExpression, $0.value.sqlExpression.jsonBuilderExpression] }
    }

    public static func json(_ value: some SQLExpressible) -> SQLExpression {
      call("JSON", [value.sqlExpression])
    }

    public static func jsonArray(_ values: some Collection<some SQLExpressible>) -> SQLExpression {
      call("JSON_ARRAY", values.map(\.sqlExpression.jsonBuilderExpression))
    }

    public static func jsonArray(_ values: some Collection<any SQLExpressible>) -> SQLExpression {
      call("JSON_ARRAY", values.map(\.sqlExpression.jsonBuilderExpression))
    }

    public static func jsonArrayLength(_ value: some SQLExpressible) -> SQLExpression {
      call("JSON_ARRAY_LENGTH", [value.sqlExpression])
    }

    public static func jsonArrayLength(
      _ value: some SQLExpressible,
      atPath path: some SQLExpressible
    ) -> SQLExpression {
      call("JSON_ARRAY_LENGTH", [value.sqlExpression, path.sqlExpression])
    }

    public static func jsonErrorPosition(_ value: some SQLExpressible) -> SQLExpression {
      call("JSON_ERROR_POSITION", [value.sqlExpression])
    }

    public static func jsonExtract(_ value: some SQLExpressible, atPath path: some SQLExpressible)
      -> SQLExpression
    {
      call("JSON_EXTRACT", [value.sqlExpression, path.sqlExpression])
    }

    public static func jsonExtract(
      _ value: some SQLExpressible,
      atPaths paths: some Collection<some SQLExpressible>
    ) -> SQLExpression {
      call("JSON_EXTRACT", [value.sqlExpression] + paths.map(\.sqlExpression))
    }

    public static func jsonInsert(
      _ value: some SQLExpressible,
      _ assignments: some Collection<(key: String, value: any SQLExpressible)>
    ) -> SQLExpression {
      call("JSON_INSERT", Self.assignments(value, assignments))
    }

    public static func jsonReplace(
      _ value: some SQLExpressible,
      _ assignments: some Collection<(key: String, value: any SQLExpressible)>
    ) -> SQLExpression {
      call("JSON_REPLACE", Self.assignments(value, assignments))
    }

    public static func jsonSet(
      _ value: some SQLExpressible,
      _ assignments: some Collection<(key: String, value: any SQLExpressible)>
    ) -> SQLExpression {
      call("JSON_SET", Self.assignments(value, assignments))
    }

    public static func jsonObject(
      _ elements: some Collection<(key: String, value: any SQLExpressible)>
    ) -> SQLExpression {
      call("JSON_OBJECT", objectElements(elements))
    }

    public static func jsonPatch(_ value: some SQLExpressible, with patch: some SQLExpressible)
      -> SQLExpression
    {
      call("JSON_PATCH", [value.sqlExpression, patch.sqlExpression])
    }

    public static func jsonRemove(_ value: some SQLExpressible, atPath path: some SQLExpressible)
      -> SQLExpression
    {
      call("JSON_REMOVE", [value.sqlExpression, path.sqlExpression])
    }

    public static func jsonRemove(
      _ value: some SQLExpressible,
      atPaths paths: some Collection<some SQLExpressible>
    ) -> SQLExpression {
      call("JSON_REMOVE", [value.sqlExpression] + paths.map(\.sqlExpression))
    }

    public static func jsonType(_ value: some SQLExpressible) -> SQLExpression {
      call("JSON_TYPE", [value.sqlExpression])
    }

    public static func jsonType(_ value: some SQLExpressible, atPath path: some SQLExpressible)
      -> SQLExpression
    {
      call("JSON_TYPE", [value.sqlExpression, path.sqlExpression])
    }

    public static func jsonIsValid(_ value: some SQLExpressible) -> SQLExpression {
      call("JSON_VALID", [value.sqlExpression])
    }

    public static func jsonIsValid(
      _ value: some SQLExpressible,
      options: JSONValidationOptions?
    ) -> SQLExpression {
      if let options {
        return call("JSON_VALID", [value.sqlExpression, options.rawValue.sqlExpression])
      }
      return call("JSON_VALID", [value.sqlExpression])
    }

    public static func jsonQuote(_ value: some SQLExpressible) -> SQLExpression {
      call("JSON_QUOTE", [value.sqlExpression.jsonBuilderExpression])
    }

    public static func jsonGroupArray(
      _ value: some SQLExpressible,
      orderBy ordering: (any SQLOrderingTerm)? = nil,
      filter: (any SQLSpecificExpressible)? = nil
    ) -> SQLExpression {
      .aggregate(
        "JSON_GROUP_ARRAY",
        [value.sqlExpression.jsonBuilderExpression],
        ordering: ordering?.sqlOrdering,
        filter: filter?.sqlExpression
      )
    }

    public static func jsonGroupObject(
      key: some SQLExpressible,
      value: some SQLExpressible,
      filter: (any SQLSpecificExpressible)? = nil
    ) -> SQLExpression {
      .aggregate(
        "JSON_GROUP_OBJECT",
        [key.sqlExpression, value.sqlExpression.jsonBuilderExpression],
        filter: filter?.sqlExpression
      )
    }

    public static func jsonb(_ value: some SQLExpressible) -> SQLExpression {
      call("JSONB", [value.sqlExpression])
    }

    public static func jsonbArray(_ values: some Collection<some SQLExpressible>) -> SQLExpression {
      call("JSONB_ARRAY", values.map(\.sqlExpression.jsonBuilderExpression))
    }

    public static func jsonbArray(_ values: some Collection<any SQLExpressible>) -> SQLExpression {
      call("JSONB_ARRAY", values.map(\.sqlExpression.jsonBuilderExpression))
    }

    public static func jsonbExtract(_ value: some SQLExpressible, atPath path: some SQLExpressible)
      -> SQLExpression
    {
      call("JSONB_EXTRACT", [value.sqlExpression, path.sqlExpression])
    }

    public static func jsonbExtract(
      _ value: some SQLExpressible,
      atPaths paths: some Collection<some SQLExpressible>
    ) -> SQLExpression {
      call("JSONB_EXTRACT", [value.sqlExpression] + paths.map(\.sqlExpression))
    }

    public static func jsonbInsert(
      _ value: some SQLExpressible,
      _ assignments: some Collection<(key: String, value: any SQLExpressible)>
    ) -> SQLExpression {
      call("JSONB_INSERT", Self.assignments(value, assignments))
    }

    public static func jsonbReplace(
      _ value: some SQLExpressible,
      _ assignments: some Collection<(key: String, value: any SQLExpressible)>
    ) -> SQLExpression {
      call("JSONB_REPLACE", Self.assignments(value, assignments))
    }

    public static func jsonbSet(
      _ value: some SQLExpressible,
      _ assignments: some Collection<(key: String, value: any SQLExpressible)>
    ) -> SQLExpression {
      call("JSONB_SET", Self.assignments(value, assignments))
    }

    public static func jsonbObject(
      _ elements: some Collection<(key: String, value: any SQLExpressible)>
    ) -> SQLExpression {
      call("JSONB_OBJECT", objectElements(elements))
    }

    public static func jsonbPatch(_ value: some SQLExpressible, with patch: some SQLExpressible)
      -> SQLExpression
    {
      call("JSONB_PATCH", [value.sqlExpression, patch.sqlExpression])
    }

    public static func jsonbRemove(_ value: some SQLExpressible, atPath path: some SQLExpressible)
      -> SQLExpression
    {
      call("JSONB_REMOVE", [value.sqlExpression, path.sqlExpression])
    }

    public static func jsonbRemove(
      _ value: some SQLExpressible,
      atPaths paths: some Collection<some SQLExpressible>
    ) -> SQLExpression {
      call("JSONB_REMOVE", [value.sqlExpression] + paths.map(\.sqlExpression))
    }

    public static func jsonbGroupArray(
      _ value: some SQLExpressible,
      orderBy ordering: (any SQLOrderingTerm)? = nil,
      filter: (any SQLSpecificExpressible)? = nil
    ) -> SQLExpression {
      .aggregate(
        "JSONB_GROUP_ARRAY",
        [value.sqlExpression.jsonBuilderExpression],
        ordering: ordering?.sqlOrdering,
        filter: filter?.sqlExpression
      )
    }

    public static func jsonbGroupObject(
      key: some SQLExpressible,
      value: some SQLExpressible,
      filter: (any SQLSpecificExpressible)? = nil
    ) -> SQLExpression {
      .aggregate(
        "JSONB_GROUP_OBJECT",
        [key.sqlExpression, value.sqlExpression.jsonBuilderExpression],
        filter: filter?.sqlExpression
      )
    }
  }
#endif
