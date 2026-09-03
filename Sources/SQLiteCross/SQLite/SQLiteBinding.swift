import Foundation
import StructuredQueries

/// Binds one Structured Queries value to a prepared statement.
func bind(
  _ binding: QueryBinding,
  to statement: OpaquePointer,
  at index: Int32,
  library: UnsafePointer<SQLiteLibrary>
) throws {
  let code: Int32
  switch binding {
  case .blob(let bytes):
    code = bytes.withUnsafeBytes { buffer in
      // A null pointer binds SQL NULL, so an empty blob needs a pointer that is merely unread.
      guard let baseAddress = buffer.baseAddress else {
        var empty: UInt8 = 0
        return withUnsafeBytes(of: &empty) {
          library.pointee.bind_blob(statement, index, $0.baseAddress, 0)
        }
      }
      return library.pointee.bind_blob(statement, index, baseAddress, Int32(buffer.count))
    }
  case .bool(let bool):
    code = library.pointee.bind_int64(statement, index, bool ? 1 : 0)
  case .date(let date):
    code = bindText(date.sqliteCrossISO8601String, to: statement, at: index, library: library)
  case .double(let double):
    code = library.pointee.bind_double(statement, index, double)
  case .int(let integer):
    code = library.pointee.bind_int64(statement, index, integer)
  case .null:
    code = library.pointee.bind_null(statement, index)
  case .text(let string):
    code = bindText(string, to: statement, at: index, library: library)
  case .uint(let integer):
    guard integer <= UInt64(Int64.max) else {
      throw DatabaseIntegerOverflowError(value: integer)
    }
    code = library.pointee.bind_int64(statement, index, Int64(integer))
  case .uuid(let uuid):
    code = bindText(uuid.uuidString.lowercased(), to: statement, at: index, library: library)
  case .invalid(let error):
    throw error.underlyingError
  }
  guard code == SQLiteResultCode.ok.rawValue else {
    throw SQLiteError(code: SQLiteResultCode(rawValue: code), message: "could not bind parameter")
  }
}

/// Binds `string` as text, keeping every byte of it.
///
/// The byte count is passed explicitly rather than left to SQLite to measure. A Swift string may
/// contain a NUL, and asking SQLite to stop at the first one would silently store a prefix of the
/// value the caller asked to store.
private func bindText(
  _ string: String,
  to statement: OpaquePointer,
  at index: Int32,
  library: UnsafePointer<SQLiteLibrary>
) -> Int32 {
  var string = string
  return string.withUTF8 { buffer in
    guard let baseAddress = buffer.baseAddress else {
      // An empty string has no storage to point at, and a null pointer would bind SQL NULL rather
      // than empty text.
      return "".withCString { library.pointee.bind_text(statement, index, $0, 0) }
    }
    return baseAddress.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
      library.pointee.bind_text(statement, index, $0, Int32(buffer.count))
    }
  }
}

/// Renders a Structured Queries fragment into SQL and the bindings it needs.
func prepareQuery(_ query: QueryFragment) -> (sql: String, bindings: [QueryBinding]) {
  let prepared = query.prepare { _ in "?" }
  guard !prepared.sql.isEmpty else {
    // A query builder can legitimately produce no SQL, such as `Values` with no rows. SQLite
    // cannot prepare an empty string, so stand in a statement that selects nothing.
    return ("SELECT 1 WHERE 0 -- empty query", [])
  }
  return (prepared.sql, prepared.bindings)
}
