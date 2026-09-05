#if SystemSQLite
  import Foundation
  import CSQLite3
  import StructuredQueriesSQLite

  /// Decodes a database function's arguments.
  ///
  /// A ported copy: swift-structured-queries implements this, but in a target it does not ship as
  /// a product, so no other package can reach it.
  struct SQLiteFunctionDecoder: QueryDecoder {
    let argumentCount: Int32
    let arguments: UnsafeMutablePointer<OpaquePointer?>?
    var currentIndex: Int32 = 0

    init(argumentCount: Int32, arguments: UnsafeMutablePointer<OpaquePointer?>?) {
      self.argumentCount = argumentCount
      self.arguments = arguments
    }

    /// Steps past the current argument, returning it when its storage class is `expected`, `nil`
    /// when it is `NULL`, and throwing otherwise.
    private mutating func argument(
      _ expected: Int32,
      for columnType: Any.Type
    ) throws(QueryDecodingError) -> OpaquePointer? {
      precondition(argumentCount > currentIndex)
      let value = arguments?[Int(currentIndex)]
      switch sqlite3_value_type(value) {
      case SQLITE_NULL:
        currentIndex += 1
        return nil
      case expected:
        currentIndex += 1
        return value
      default:
        throw QueryDecodingError.typeMismatch(columnType)
      }
    }

    mutating func decode(_ columnType: [UInt8].Type) throws(QueryDecodingError) -> [UInt8]? {
      guard let value = try argument(SQLITE_BLOB, for: columnType) else { return nil }
      // A zero-length blob has no buffer to point at.
      guard let blob = sqlite3_value_blob(value) else { return [] }
      return [UInt8](UnsafeRawBufferPointer(start: blob, count: Int(sqlite3_value_bytes(value))))
    }

    mutating func decode(_ columnType: Double.Type) throws(QueryDecodingError) -> Double? {
      try argument(SQLITE_FLOAT, for: columnType).map(sqlite3_value_double)
    }

    mutating func decode(_ columnType: Int64.Type) throws(QueryDecodingError) -> Int64? {
      try argument(SQLITE_INTEGER, for: columnType).map(sqlite3_value_int64)
    }

    mutating func decode(_ columnType: String.Type) throws(QueryDecodingError) -> String? {
      try argument(SQLITE_TEXT, for: columnType).map { String(cString: sqlite3_value_text($0)) }
    }

    mutating func decode(_ columnType: Bool.Type) throws(QueryDecodingError) -> Bool? {
      try decode(Int64.self).map { $0 != 0 }
    }

    mutating func decode(_ columnType: Int.Type) throws(QueryDecodingError) -> Int? {
      try decode(Int64.self).map(Int.init)
    }

    mutating func decode(_ columnType: UInt64.Type) throws(QueryDecodingError) -> UInt64? {
      guard let value = try decode(Int64.self) else { return nil }
      guard value >= 0 else {
        throw QueryDecodingError.other(DatabaseIntegerOverflowError(value: value))
      }
      return UInt64(value)
    }

    mutating func decode(_ columnType: Date.Type) throws(QueryDecodingError) -> Date? {
      guard let value = try decode(String.self) else { return nil }
      do {
        return try Date(orbitISO8601String: value)
      } catch {
        throw QueryDecodingError.other(error)
      }
    }

    mutating func decode(_ columnType: UUID.Type) throws(QueryDecodingError) -> UUID? {
      guard let value = try decode(String.self) else { return nil }
      guard let uuid = UUID(uuidString: value) else {
        throw QueryDecodingError.other(InvalidDatabaseUUIDError())
      }
      return uuid
    }
  }

  /// SQLite's marker for "copy this value", which the C headers define as a macro that Swift does
  /// not import.
  private let sqliteTransient = unsafeBitCast(
    -1,
    to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self
  )

  extension QueryBinding {
    /// Returns this binding as a database function's result.
    func result(_ context: OpaquePointer?) {
      switch self {
      case .blob(let blob):
        sqlite3_result_blob(context, Array(blob), Int32(blob.count), sqliteTransient)
      case .bool(let bool):
        sqlite3_result_int64(context, bool ? 1 : 0)
      case .date(let date):
        sqlite3_result_text(context, date.orbitISO8601String, -1, sqliteTransient)
      case .double(let double):
        sqlite3_result_double(context, double)
      case .int(let int):
        sqlite3_result_int64(context, int)
      case .null:
        sqlite3_result_null(context)
      case .text(let text):
        sqlite3_result_text(context, text, -1, sqliteTransient)
      case .uint(let uint) where uint <= UInt64(Int64.max):
        sqlite3_result_int64(context, Int64(uint))
      case .uint(let uint):
        sqlite3_result_error(context, "Unsigned integer \(uint) overflows Int64.max", -1)
      case .uuid(let uuid):
        sqlite3_result_text(context, uuid.uuidString.lowercased(), -1, sqliteTransient)
      case .invalid(let error):
        sqlite3_result_error(context, "\(error.underlyingError)", -1)
      }
    }
  }
#endif
