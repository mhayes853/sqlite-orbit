/// An error reported by SQLite.
public struct SQLiteError: Error, Hashable, Sendable {
  /// The extended result code, which carries the primary code in its low byte.
  public let code: SQLiteResultCode

  /// The message SQLite associated with the failing connection, when one was available.
  public let message: String?

  /// The SQL being prepared or run when the failure was reported.
  public let sql: String?

  public init(code: SQLiteResultCode, message: String? = nil, sql: String? = nil) {
    self.code = code
    self.message = message
    self.sql = sql
  }

  /// The primary result code, with any extended result bits removed.
  public var primaryCode: SQLiteResultCode {
    code.primary
  }
}

extension SQLiteError: CustomStringConvertible {
  public var description: String {
    var description = "SQLite error \(code.rawValue)"
    if let message {
      description += ": \(message)"
    }
    if let sql {
      description += " (while running: \(sql))"
    }
    return description
  }
}
