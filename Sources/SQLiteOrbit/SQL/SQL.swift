#if StructuredQueries
  public import StructuredQueriesSQLite
#endif

/// Raw SQL with its parameters bound rather than spliced in.
///
/// Write SQL as a string literal. An interpolated value becomes a `?` parameter bound to it, so it
/// can never change the statement's meaning, while an interpolated `SQL` is spliced in with its own
/// parameters, which is how a statement is composed from parts.
///
/// ```swift
/// let title = "Get milk"
/// let reminders = try await database.read { transaction in
///   try transaction.fetchAll(
///     "SELECT id, title FROM reminders WHERE title = \(title) ORDER BY id"
///   ) { row in
///     (row[0].integerValue ?? 0, row[1].textValue ?? "")
///   }
/// }
/// ```
///
/// Text that must be spliced in — an identifier or a keyword chosen at runtime — goes through
/// `\(quote:)` or, for text already known to be safe, `\(raw:)`.
///
/// ```swift
/// let table = "reminders"
/// let order: SQL = isAscending ? "ASC" : "DESC"
/// let query: SQL = "SELECT title FROM \(quote: table) ORDER BY title \(order)"
/// ```
///
/// There is deliberately no unlabeled initializer from a `String` value: SQL built at runtime has
/// to say how its text is to be treated, by interpolating it with `\(raw:)` or `\(quote:)`, or by
/// handing it over as already-written SQL through ``init(text:bindings:)``.
public struct SQL: Hashable, Sendable {
  /// An ordered piece of SQL, preserving the boundary between SQL text and interpolated values.
  public enum Part: Hashable, Sendable {
    /// SQL text, used verbatim. It may contain SQL literals, identifiers, or raw placeholders.
    case text(String)

    /// A value interpolated as an anonymous `?` parameter.
    case binding(OrbitDatabaseValue)

    /// Prebound raw SQL whose placeholders are already present in `text`.
    ///
    /// Numbered and named placeholders are preserved verbatim. To execute the complete SQL,
    /// concatenate all text and append all bindings in part order, then bind that complete list
    /// by index. Placeholder indices refer to the complete statement; they are not rebased when
    /// fragments are appended. This case does not parse or reorder raw placeholders.
    case statement(text: String, bindings: [OrbitDatabaseValue])
  }

  private var parts: [Part]
  private var bindingFailure: (any Error)?

  /// The SQL text, with a `?` for each interpolated value and raw placeholders left intact.
  ///
  /// This is an unvalidated projection. Execution adapters should first use ``validatedParts()``
  /// so a failed value conversion cannot silently become a `NULL` binding.
  public var text: String {
    parts.reduce(into: "") { text, part in
      switch part {
      case .text(let fragment), .statement(let fragment, _): text.append(fragment)
      case .binding: text.append("?")
      }
    }
  }

  /// The parameter values in construction order, including those supplied with raw SQL.
  ///
  /// Like ``text``, this projection does not report deferred conversion errors. Use
  /// ``validatedParts()`` before adapting the SQL for execution.
  public var bindings: [OrbitDatabaseValue] {
    parts.reduce(into: []) { bindings, part in
      switch part {
      case .text: break
      case .binding(let value): bindings.append(value)
      case .statement(_, let values): bindings.append(contentsOf: values)
      }
    }
  }

  /// Creates SQL by concatenating ordered parts without interpreting their text.
  ///
  /// Parts need not alternate between text and bindings. Every binding contributes one `?`;
  /// prebound statements retain their existing placeholders and parameter values.
  public init(parts: [Part]) {
    self.parts = parts
  }

  /// Returns the construction parts, throwing any error captured while converting a binding.
  ///
  /// This validates value conversion only. SQL syntax and parameter indices are checked by the
  /// database when it prepares and binds the statement. The array preserves construction order;
  /// adjacent text or binding parts are valid, and equal SQL can have different part boundaries.
  ///
  /// ```swift
  /// let sql: SQL = "SELECT * FROM reminders WHERE title = \("Milk")"
  /// let parts = try sql.validatedParts()
  /// // [.text("SELECT * FROM reminders WHERE title = "), .binding(.text("Milk"))]
  /// ```
  public func validatedParts() throws -> [Part] {
    if let bindingFailure { throw bindingFailure }
    return parts
  }

  /// Creates SQL from text that is already written, with values for its parameters.
  ///
  /// The text is used as it is, so it must come from the program itself rather than from input:
  /// nothing in it is escaped or quoted. Values in `bindings` are assigned SQLite parameter
  /// indices starting at one. Numbered and named placeholders follow SQLite's normal indexing
  /// rules, including repeated references to the same parameter.
  ///
  /// ```swift
  /// let query = SQL(
  ///   text: "SELECT title FROM reminders WHERE list_id = ? AND is_completed = ?",
  ///   bindings: [.integer(listID), .integer(0)]
  /// )
  /// ```
  ///
  /// The counts are not checked here, but SQLite holds a statement to them when it runs: a
  /// parameter left without a value is bound to `NULL`, and a value left without a parameter fails
  /// the statement before it runs with a ``SQLiteError`` whose code is `SQLITE_RANGE`.
  ///
  /// - Parameters:
  ///   - text: The SQL text, with a parameter standing in for each value.
  ///   - bindings: The values bound to the text's parameters, in order.
  public init(text: String, bindings: [OrbitDatabaseValue] = []) {
    self.init(
      parts: bindings.isEmpty ? [.text(text)] : [.statement(text: text, bindings: bindings)]
    )
  }

  /// Appends another statement's text and parameters to this one.
  ///
  /// ```swift
  /// var query: SQL = "SELECT title FROM reminders"
  /// if let listID {
  ///   query.append(" WHERE list_id = \(listID)")
  /// }
  /// ```
  ///
  /// - Parameter other: The SQL to append.
  public mutating func append(_ other: SQL) {
    parts.append(contentsOf: other.parts)
    if bindingFailure == nil {
      bindingFailure = other.bindingFailure
    }
  }

  /// Concatenates two statements' text and parameters.
  ///
  /// ```swift
  /// let query: SQL = "SELECT title FROM reminders" + " WHERE id = \(id)"
  /// ```
  ///
  /// - Parameters:
  ///   - lhs: The leading SQL.
  ///   - rhs: The SQL to append to it.
  /// - Returns: The two joined, with `lhs`'s parameters ahead of `rhs`'s.
  public static func + (lhs: SQL, rhs: SQL) -> SQL {
    var sql = lhs
    sql.append(rhs)
    return sql
  }
}

extension SQL {
  /// Compares executable text, parameter values, and whether binding conversion succeeded.
  /// Construction boundaries and the particular conversion error do not affect equality.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.text == rhs.text && lhs.bindings == rhs.bindings
      && (lhs.bindingFailure == nil) == (rhs.bindingFailure == nil)
  }

  /// Hashes executable text, parameter values, and conversion validity.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(text)
    hasher.combine(bindings)
    hasher.combine(bindingFailure == nil)
  }
}

extension Sequence<SQL> {
  /// Concatenates the statements, putting `separator` between each.
  ///
  /// ```swift
  /// let conditions: [SQL] = ["is_completed = \(false)", "priority >= \(2)"]
  /// let query: SQL =
  ///   "SELECT title FROM reminders WHERE \(conditions.joined(separator: " AND "))"
  /// ```
  ///
  /// - Parameter separator: The SQL to put between each element. Defaults to nothing.
  /// - Returns: The joined SQL, or empty SQL for an empty sequence.
  public func joined(separator: SQL = "") -> SQL {
    var joined: SQL = ""
    var isFirst = true
    for sql in self {
      if isFirst {
        isFirst = false
      } else {
        joined.append(separator)
      }
      joined.append(sql)
    }
    return joined
  }
}

extension SQL: ExpressibleByStringInterpolation {
  /// Creates SQL from a literal with no interpolations.
  ///
  /// ```swift
  /// let query: SQL = "SELECT count(*) FROM reminders"
  /// ```
  ///
  /// - Parameter value: The SQL text.
  public init(stringLiteral value: String) {
    self.init(text: value, bindings: [])
  }

  /// Creates SQL from a literal, binding each interpolated value as a parameter.
  ///
  /// - Parameter stringInterpolation: The literal's text and interpolations.
  public init(stringInterpolation: StringInterpolation) {
    self = stringInterpolation.sql
  }

  /// Builds ``SQL`` from a string literal.
  ///
  /// A ``ConvertibleToOrbitDatabaseValue`` is bound as a parameter, ``SQL`` is spliced in along
  /// with its own parameters, and `\(raw:)` and `\(quote:)` splice text in directly.
  ///
  /// ```swift
  /// let query: SQL = """
  ///   SELECT \(quote: column) FROM reminders
  ///   WHERE list_id = \(listID) AND title LIKE \("%" + search + "%")
  ///   """
  /// ```
  public struct StringInterpolation: StringInterpolationProtocol {
    var sql: SQL

    /// Creates an empty interpolation, reserving room for the literal.
    ///
    /// - Parameters:
    ///   - literalCapacity: The combined length of the literal's text segments.
    ///   - interpolationCount: How many interpolations the literal has.
    public init(literalCapacity: Int, interpolationCount: Int) {
      self.sql = SQL(parts: [])
      self.sql.parts.reserveCapacity(interpolationCount * 2 + 1)
    }

    /// Appends literal SQL text.
    ///
    /// - Parameter literal: The text.
    public mutating func appendLiteral(_ literal: String) {
      if !literal.isEmpty { sql.parts.append(.text(literal)) }
    }

    /// Binds a value as a parameter.
    ///
    /// The value is never spliced into the SQL, so it cannot change the statement's meaning.
    /// A failed conversion leaves a `NULL` placeholder in the unvalidated projections;
    /// ``SQL/validatedParts()`` and execution throw its error before binding any values.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE priority = \(Priority.high)"
    /// ```
    ///
    /// - Parameter value: The value to bind.
    public mutating func appendInterpolation(_ value: some ConvertibleToOrbitDatabaseValue) {
      do {
        sql.parts.append(.binding(try value.orbitDatabaseValue()))
      } catch {
        sql.parts.append(.binding(.null))
        if sql.bindingFailure == nil { sql.bindingFailure = error }
      }
    }

    /// Binds a storage value as a parameter.
    ///
    /// This only exists so a storage value can be written as an implicit member, or as `nil`.
    ///
    /// ```swift
    /// let query: SQL = "INSERT INTO notes (id, body) VALUES (\(.integer(1)), \(.null))"
    /// ```
    ///
    /// - Parameter value: The value to bind.
    public mutating func appendInterpolation(_ value: OrbitDatabaseValue) {
      sql.parts.append(.binding(value))
    }

    /// Splices in other SQL, along with its parameters.
    ///
    /// ```swift
    /// let filter: SQL = "is_completed = \(false)"
    /// let query: SQL = "SELECT title FROM reminders WHERE \(filter)"
    /// ```
    ///
    /// - Parameter sql: The SQL to splice in.
    public mutating func appendInterpolation(_ sql: SQL) {
      self.sql.append(sql)
    }

    /// Splices text into the SQL as it is.
    ///
    /// - Warning: The text becomes part of the statement, so text that did not come from the
    ///   program itself opens it to SQL injection. Bind values instead, and splice identifiers
    ///   with `\(quote:)`.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders ORDER BY title \(raw: "DESC")"
    /// ```
    ///
    /// - Parameter text: The SQL text.
    public mutating func appendInterpolation(raw text: String) {
      appendLiteral(text)
    }

    /// Splices in an identifier, wrapped in double quotes with any double quote inside it doubled.
    ///
    /// ```swift
    /// let query: SQL = "SELECT \(quote: "title") FROM \(quote: "reminders")"
    /// // SELECT "title" FROM "reminders"
    /// ```
    ///
    /// - Parameter identifier: The table, column, or other name to quote.
    public mutating func appendInterpolation(quote identifier: String) {
      appendLiteral(orbitQuoted(identifier, delimiter: "\""))
    }
  }
}

extension SQL: CustomDebugStringConvertible {
  /// The SQL with each parameter replaced by the literal it is bound to.
  ///
  /// This is for reading, not running: it is not escaped the way a statement has to be.
  public var debugDescription: String {
    var description = ""
    var bindings = self.bindings.makeIterator()
    var quote: Character?
    for character in text {
      if let open = quote {
        if character == open { quote = nil }
        description.append(character)
        continue
      }
      switch character {
      case "'", "\"", "`":
        quote = character
        description.append(character)
      case "?":
        description.append(bindings.next()?.debugDescription ?? "?")
      default:
        description.append(character)
      }
    }
    return description
  }
}

// Wraps `text` in `delimiter`, doubling any delimiter inside it, which is how SQLite escapes an
// identifier or a string literal. It works on scalars rather than characters so that a delimiter
// followed by a combining mark is still doubled, as SQLite, which sees only bytes, requires.
func orbitQuoted(_ text: String, delimiter: Unicode.Scalar) -> String {
  var quoted = ""
  quoted.reserveCapacity(text.utf8.count + 2)
  quoted.unicodeScalars.append(delimiter)
  for scalar in text.unicodeScalars {
    if scalar == delimiter { quoted.unicodeScalars.append(delimiter) }
    quoted.unicodeScalars.append(scalar)
  }
  quoted.unicodeScalars.append(delimiter)
  return quoted
}

// MARK: - Structured Queries

#if StructuredQueries
  extension SQL {
    /// Creates SQL from a Structured Queries fragment, binding its values the way a statement
    /// built with the query builder always has been.
    ///
    /// Dates bind as ISO 8601 text, UUIDs as lowercase text, and Booleans as `1` or `0`, so a
    /// fragment runs exactly as the statement it came from would.
    ///
    /// ```swift
    /// let sql = SQL(fragment: Reminder.where { !$0.isCompleted }.query)
    /// ```
    ///
    /// - Parameter fragment: The fragment to lower.
    public init(fragment: QueryFragment) {
      self.init(parts: [])
      parts.reserveCapacity(fragment.segments.count)
      for segment in fragment.segments {
        switch segment {
        case .sql(let text):
          parts.append(.text(text))
        case .identifier(let identifier):
          parts.append(.text(orbitQuoted(identifier.name, delimiter: "\"")))
        case .binding(let binding):
          do {
            parts.append(.binding(try OrbitDatabaseValue(lowering: binding)))
          } catch {
            parts.append(.binding(.null))
            if bindingFailure == nil { bindingFailure = error }
          }
        }
      }
    }
  }

  extension SQL.StringInterpolation {
    /// Splices in a Structured Queries expression, along with its bindings.
    ///
    /// ```swift
    /// let query: SQL = "SELECT count(*) FROM reminders WHERE \(Reminder.columns.isCompleted)"
    /// ```
    ///
    /// A value that is also ``ConvertibleToOrbitDatabaseValue``, such as an `Int` or a `Date`, is
    /// bound through that conformance instead, so it binds the same with this trait on or off.
    ///
    /// - Parameter expression: The expression to splice in.
    @_disfavoredOverload
    public mutating func appendInterpolation(_ expression: some QueryExpression) {
      appendInterpolation(SQL(fragment: expression.queryFragment))
    }
  }

  extension OrbitDatabaseValue {
    // Throws for a binding SQLite cannot store: one the query builder already reported as invalid,
    // or an unsigned integer too large for SQLite's signed 64-bit integers.
    init(lowering binding: QueryBinding) throws {
      switch binding {
      case .blob(let bytes):
        self = .blob(bytes)
      case .bool(let bool):
        self = .integer(bool ? 1 : 0)
      case .date(let date):
        self.init(date)
      case .double(let double):
        self = .real(double)
      case .int(let integer):
        self = .integer(integer)
      case .null:
        self = .null
      case .text(let text):
        self = .text(text)
      case .uint(let integer):
        guard integer <= UInt64(Int64.max) else {
          throw OrbitDatabaseIntegerOverflowError(value: integer)
        }
        self = .integer(Int64(integer))
      case .uuid(let uuid):
        self.init(uuid)
      case .invalid(let error):
        throw error.underlyingError
      }
    }
  }
#endif
