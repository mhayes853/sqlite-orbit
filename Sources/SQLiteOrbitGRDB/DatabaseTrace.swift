#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  // MARK: - Per-connection state

  // Overlay `Database` values are created for each access, while GRDB keeps tracing and
  // transaction callbacks for the lifetime of a connection. This state is keyed by the native
  // connection handle. Overlay configurations reset it first thing when a connection opens, so a
  // handle address reused by a later connection never inherits callbacks.
  final class DatabaseConnectionState: @unchecked Sendable {
    var traceOptions: Database.TracingOptions = []
    var trace: ((Database.TraceEvent) -> Void)?
    var publicStatementArguments = false
    var configuration: Configuration?
    var transactionDate: Result<Date, Error>?
    var afterNextTransaction: [(onCommit: (Database) -> Void, onRollback: (Database) -> Void)] = []

    func transactionDidEnd(_ db: Database, committed: Bool) {
      guard !afterNextTransaction.isEmpty else { return }
      let callbacks = afterNextTransaction
      afterNextTransaction = []
      for callback in callbacks {
        committed ? callback.onCommit(db) : callback.onRollback(db)
      }
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var states: [UInt: DatabaseConnectionState] = [:]

    static func state(for connection: OpaquePointer) -> DatabaseConnectionState {
      let key = UInt(bitPattern: Int(bitPattern: UnsafeMutableRawPointer(connection)))
      return lock.withLock {
        if let state = states[key] {
          return state
        }
        let state = DatabaseConnectionState()
        states[key] = state
        return state
      }
    }

    static func reset(_ connection: OpaquePointer) {
      let key = UInt(bitPattern: Int(bitPattern: UnsafeMutableRawPointer(connection)))
      lock.withLock { states[key] = nil }
    }
  }

  extension Database {
    var connectionState: DatabaseConnectionState {
      if let state = _connectionState {
        return state
      }
      let state = DatabaseConnectionState.state(for: try! access.sqliteConnection)
      _connectionState = state
      return state
    }
  }

  // MARK: - Tracing

  extension Database {
    /// Options for `trace(options:_:)`.
    public struct TracingOptions: OptionSet, Sendable {
      public let rawValue: CInt

      public init(rawValue: CInt) {
        self.rawValue = rawValue
      }

      /// Reports each statement when its execution starts.
      public static let statement = TracingOptions(rawValue: 0x01)

      /// Reports each statement and its duration when its execution ends.
      public static let profile = TracingOptions(rawValue: 0x02)
    }

    /// A trace event.
    public enum TraceEvent: CustomStringConvertible, Sendable {
      /// Information about an executed statement.
      public struct Statement: CustomStringConvertible, Sendable {
        let unexpandedSQL: String
        let values: [DatabaseValue]
        let parameters: [(range: Range<Int>, slot: Int)]
        let publicStatementArguments: Bool

        /// The executed SQL, where bound parameters are not expanded.
        public var sql: String {
          unexpandedSQL.hasPrefix("--") ? unexpandedSQL : trimmedStatement(unexpandedSQL)
        }

        /// The executed SQL, where bound parameters are expanded.
        public var expandedSQL: String {
          if unexpandedSQL.hasPrefix("--") || parameters.isEmpty {
            return sql
          }
          var bytes = Array(unexpandedSQL.utf8)
          for (range, slot) in parameters.reversed() where slot < values.count {
            bytes.replaceSubrange(range, with: sqlLiteral(values[slot]).utf8)
          }
          return trimmedStatement(String(decoding: bytes, as: UTF8.self))
        }

        public var description: String {
          publicStatementArguments ? expandedSQL : sql
        }
      }

      case statement(Statement)
      case profile(statement: Statement, duration: TimeInterval)

      public var description: String {
        switch self {
        case .statement(let statement):
          return statement.description
        case .profile(let statement, let duration):
          return "\(String(format: "%.3f", duration))s \(statement)"
        }
      }

      public var expandedDescription: String {
        switch self {
        case .statement(let statement):
          return statement.expandedSQL
        case .profile(let statement, let duration):
          return "\(String(format: "%.3f", duration))s \(statement.expandedSQL)"
        }
      }
    }

    /// Registers a tracing function for this connection.
    ///
    /// Events describe the statements executed through the compatibility `Database`, including
    /// the transaction statements of its managed transactions. Statements executed through
    /// SQLiteOrbit's native APIs, or by SQLite triggers, are not reported. Pass an empty options
    /// set or a nil function to stop tracing.
    public func trace(options: TracingOptions = .statement, _ trace: ((TraceEvent) -> Void)? = nil)
    {
      let state = connectionState
      if options.isEmpty || trace == nil {
        state.traceOptions = []
        state.trace = nil
      } else {
        state.traceOptions = options
        state.trace = trace
      }
    }

    /// Starts a statement trace. The returned token reports the profile event when it ends.
    func traceStatement(sql: String, values: [DatabaseValue]) -> StatementTrace? {
      let state = connectionState
      guard let trace = state.trace, !state.traceOptions.isEmpty else {
        return nil
      }
      var parameters: [(range: Range<Int>, slot: Int)] = []
      if !values.isEmpty {
        _ = try? bindArguments(
          StatementArguments(values),
          sql: sql,
          allowRemaining: true,
          allowMissing: true,
          parameter: { parameters.append(($0, $1)) }
        )
      }
      let statement = TraceEvent.Statement(
        unexpandedSQL: sql,
        values: values,
        parameters: parameters,
        publicStatementArguments: state.publicStatementArguments
      )
      if state.traceOptions.contains(.statement) {
        trace(.statement(statement))
      }
      guard state.traceOptions.contains(.profile) else {
        return nil
      }
      return StatementTrace(statement: statement, trace: trace)
    }

    /// Reports a transaction statement executed by the native managed transaction.
    func traceTransactionStatement(_ sql: String) {
      traceStatement(sql: sql, values: [])?.finish()
    }
  }

  final class StatementTrace {
    let statement: Database.TraceEvent.Statement
    let trace: (Database.TraceEvent) -> Void
    let start = DispatchTime.now()
    private var finished = false

    init(statement: Database.TraceEvent.Statement, trace: @escaping (Database.TraceEvent) -> Void) {
      self.statement = statement
      self.trace = trace
    }

    func finish() {
      guard !finished else { return }
      finished = true
      let duration =
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
      trace(.profile(statement: statement, duration: duration))
    }
  }

  // SQLite trims the statement text it reports; match `trimmedSQLStatement` in GRDB.
  private func trimmedStatement(_ sql: String) -> String {
    sql.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))
    )
  }

  // The literal spelling `sqlite3_expanded_sql` uses for bound values.
  func sqlLiteral(_ value: DatabaseValue) -> String {
    switch value.storage {
    case .null:
      return "NULL"
    case .int64(let int):
      return String(int)
    case .double(let double):
      if double.isNaN {
        return "NULL"
      }
      if double.isInfinite {
        return double < 0 ? "-Inf" : "Inf"
      }
      var text = String(format: "%.15g", double)
      if !text.contains(".") {
        if let e = text.firstIndex(of: "e") {
          text.insert(contentsOf: ".0", at: e)
        } else {
          text += ".0"
        }
      }
      return text
    case .string(let string):
      return "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
    case .blob(let data):
      return "x'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }
  }
#endif
