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

  /// The error `connection` is currently reporting, after a call returned `code`.
  @usableFromInline
  static func reported(
    by library: borrowing SQLiteLibrary,
    on connection: OpaquePointer?,
    code: Int32,
    sql: String?
  ) -> SQLiteError {
    let message = library.errmsg(connection).map { String(cString: $0) }
    // `extended_errcode` carries the same failure with more detail, but only when it is still
    // describing the failure we were handed.
    let extended = library.extended_errcode(connection)
    let resolved = (extended & 0xff) == (code & 0xff) ? extended : code
    return SQLiteError(code: SQLiteResultCode(rawValue: resolved), message: message, sql: sql)
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
