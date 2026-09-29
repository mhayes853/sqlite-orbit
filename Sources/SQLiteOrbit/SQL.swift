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
///     (row[0].integerValue!, row[1].textValue!)
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
/// There is deliberately no initializer from a `String` value: SQL built at runtime has to say how
/// its text is to be treated, by interpolating it with `\(raw:)` or `\(quote:)`.
public struct SQL: Hashable, Sendable {
  /// The SQL text, with a `?` standing in for each bound parameter.
  public private(set) var text: String

  /// The values bound to the text's parameters, in order.
  public private(set) var bindings: [OrbitDatabaseValue]

  // A value that could not be lowered to a binding, such as an unsigned integer past `Int64.max`
  // from a Structured Queries fragment. It is thrown when the statement is bound, which is where
  // the same value always failed before it could be represented here.
  var bindingFailure: SQLBindingFailure?

  init(text: String, bindings: [OrbitDatabaseValue], bindingFailure: SQLBindingFailure? = nil) {
    self.text = text
    self.bindings = bindings
    self.bindingFailure = bindingFailure
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
    text.append(other.text)
    bindings.append(contentsOf: other.bindings)
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

  // What SQLite is handed. It cannot prepare an empty string, and a composed query can
  // legitimately come out empty, so a statement that selects nothing stands in.
  var preparedText: String {
    text.isEmpty ? "SELECT 1 WHERE 0 -- empty query" : text
  }
}

struct SQLBindingFailure: Hashable, Sendable {
  let error: any Error

  // The failure is not part of what the SQL says, only of whether it can run.
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  func hash(into hasher: inout Hasher) {}
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
  /// A value is bound as a parameter, ``SQL`` is spliced in along with its own parameters, and
  /// `\(raw:)` and `\(quote:)` splice text in directly.
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
      var text = ""
      text.reserveCapacity(literalCapacity + interpolationCount)
      var bindings: [OrbitDatabaseValue] = []
      bindings.reserveCapacity(interpolationCount)
      self.sql = SQL(text: text, bindings: bindings)
    }

    /// Appends literal SQL text.
    ///
    /// - Parameter literal: The text.
    public mutating func appendLiteral(_ literal: String) {
      sql.text.append(literal)
    }

    /// Binds a value as a parameter.
    ///
    /// ```swift
    /// let query: SQL = "SELECT * FROM notes WHERE body = \(OrbitDatabaseValue.text("Hi"))"
    /// ```
    ///
    /// - Parameter value: The value to bind.
    public mutating func appendInterpolation(_ value: OrbitDatabaseValue) {
      sql.text.append("?")
      sql.bindings.append(value)
    }

    /// Binds a value as a parameter, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The value to bind.
    public mutating func appendInterpolation(_ value: OrbitDatabaseValue?) {
      appendInterpolation(value ?? .null)
    }

    /// Binds an integer as a parameter.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE id = \(id)"
    /// ```
    ///
    /// - Parameter value: The integer to bind.
    public mutating func appendInterpolation(_ value: Int) {
      appendInterpolation(.integer(Int64(value)))
    }

    /// Binds an integer as a parameter, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The integer to bind.
    public mutating func appendInterpolation(_ value: Int?) {
      appendInterpolation(value.map { .integer(Int64($0)) })
    }

    /// Binds an integer as a parameter.
    ///
    /// - Parameter value: The integer to bind.
    public mutating func appendInterpolation(_ value: Int64) {
      appendInterpolation(.integer(value))
    }

    /// Binds an integer as a parameter, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The integer to bind.
    public mutating func appendInterpolation(_ value: Int64?) {
      appendInterpolation(value.map(OrbitDatabaseValue.integer))
    }

    /// Binds a real number as a parameter.
    ///
    /// - Parameter value: The number to bind.
    public mutating func appendInterpolation(_ value: Double) {
      appendInterpolation(.real(value))
    }

    /// Binds a real number as a parameter, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The number to bind.
    public mutating func appendInterpolation(_ value: Double?) {
      appendInterpolation(value.map(OrbitDatabaseValue.real))
    }

    /// Binds a Boolean as the integer `1` or `0`, which is how SQLite spells one.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE is_completed = \(false)"
    /// ```
    ///
    /// - Parameter value: The Boolean to bind.
    public mutating func appendInterpolation(_ value: Bool) {
      appendInterpolation(.integer(value ? 1 : 0))
    }

    /// Binds a Boolean as the integer `1` or `0`, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The Boolean to bind.
    public mutating func appendInterpolation(_ value: Bool?) {
      appendInterpolation(value.map { .integer($0 ? 1 : 0) })
    }

    /// Binds text as a parameter.
    ///
    /// The text is never spliced into the SQL, so it cannot change the statement's meaning. Use
    /// `\(raw:)` or `\(quote:)` for text that is part of the statement.
    ///
    /// ```swift
    /// let query: SQL = "SELECT id FROM reminders WHERE title = \(title)"
    /// ```
    ///
    /// - Parameter value: The text to bind.
    public mutating func appendInterpolation(_ value: String) {
      appendInterpolation(.text(value))
    }

    /// Binds text as a parameter, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The text to bind.
    public mutating func appendInterpolation(_ value: String?) {
      appendInterpolation(value.map(OrbitDatabaseValue.text))
    }

    /// Binds bytes as a blob parameter.
    ///
    /// - Parameter value: The bytes to bind.
    public mutating func appendInterpolation(_ value: [UInt8]) {
      appendInterpolation(.blob(value))
    }

    /// Binds bytes as a blob parameter, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The bytes to bind.
    public mutating func appendInterpolation(_ value: [UInt8]?) {
      appendInterpolation(value.map(OrbitDatabaseValue.blob))
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
      sql.text.append(text)
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
      sql.text.append(orbitQuoted(identifier, delimiter: "\""))
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
