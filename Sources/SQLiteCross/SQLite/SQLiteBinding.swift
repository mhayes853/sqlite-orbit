import Foundation
import StructuredQueries

/// Binds one Structured Queries value to a prepared statement.
///
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
    code = date.sqliteCrossISO8601String.withCString {
      library.pointee.bind_text(statement, index, $0, -1)
    }
  case .double(let double):
    code = library.pointee.bind_double(statement, index, double)
  case .int(let integer):
    code = library.pointee.bind_int64(statement, index, integer)
  case .null:
    code = library.pointee.bind_null(statement, index)
  case .text(let string):
    code = string.withCString {
      library.pointee.bind_text(statement, index, $0, -1)
    }
  case .uint(let integer):
    guard integer <= UInt64(Int64.max) else {
      throw DatabaseIntegerOverflowError(value: integer)
    }
    code = library.pointee.bind_int64(statement, index, Int64(integer))
  case .uuid(let uuid):
    code = uuid.uuidString.lowercased().withCString {
      library.pointee.bind_text(statement, index, $0, -1)
    }
  case .invalid(let error):
    throw error.underlyingError
  }
  guard code == SQLiteResultCode.ok.rawValue else {
    throw SQLiteError(code: SQLiteResultCode(rawValue: code), message: "could not bind parameter")
  }
}

/// Renders a Structured Queries fragment into SQL and the bindings it needs.
func prepareQuery(_ query: QueryFragment) -> (sql: String, bindings: [QueryBinding]) {
  let prepared = query.prepare { _ in "?" }
  return (prepared.sql, prepared.bindings)
}
