#if StructuredQueries
  public import StructuredQueriesSQLite

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
      let (text, queryBindings) = fragment.prepare { _ in "?" }
      var bindings: [OrbitDatabaseValue] = []
      bindings.reserveCapacity(queryBindings.count)
      var failure: SQLBindingFailure?
      for binding in queryBindings {
        do {
          bindings.append(try OrbitDatabaseValue(lowering: binding))
        } catch {
          // The parameter is kept so the rest stay in position; binding throws before any runs.
          bindings.append(.null)
          if failure == nil { failure = SQLBindingFailure(error: error) }
        }
      }
      self.init(text: text, bindings: bindings, bindingFailure: failure)
    }
  }

  extension SQL.StringInterpolation {
    /// Splices in a Structured Queries expression, along with its bindings.
    ///
    /// ```swift
    /// let query: SQL = "SELECT count(*) FROM reminders WHERE \(Reminder.columns.isCompleted)"
    /// ```
    ///
    /// - Parameter expression: The expression to splice in.
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
