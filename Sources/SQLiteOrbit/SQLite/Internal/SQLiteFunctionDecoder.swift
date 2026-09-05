import Foundation
import StructuredQueriesSQLite

struct SQLiteFunctionDecoder: QueryDecoder {
  let argumentCount: Int32
  let arguments: UnsafeMutablePointer<OpaquePointer?>?
  let library: UnsafePointer<SQLiteLibrary>
  var currentIndex: Int32 = 0

  init(
    argumentCount: Int32,
    arguments: UnsafeMutablePointer<OpaquePointer?>?,
    library: UnsafePointer<SQLiteLibrary>
  ) {
    self.argumentCount = argumentCount
    self.arguments = arguments
    self.library = library
  }

  private mutating func argument(
    _ expected: SQLiteColumnType,
    for columnType: Any.Type
  ) throws(QueryDecodingError) -> OpaquePointer? {
    guard currentIndex < argumentCount else {
      throw QueryDecodingError.other(
        MissingDatabaseFunctionArgumentError(index: Int(currentIndex))
      )
    }
    let value = arguments?[Int(currentIndex)]
    switch SQLiteColumnType(rawValue: library.pointee.value_type(value)) {
    case .null:
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
    guard let value = try argument(.blob, for: columnType) else { return nil }
    // A zero-length blob has no buffer to point at.
    guard let blob = library.pointee.value_blob(value) else { return [] }
    let count = Int(library.pointee.value_bytes(value))
    return [UInt8](UnsafeRawBufferPointer(start: blob, count: count))
  }

  mutating func decode(_ columnType: Double.Type) throws(QueryDecodingError) -> Double? {
    try argument(.float, for: columnType).map(library.pointee.value_double)
  }

  mutating func decode(_ columnType: Int64.Type) throws(QueryDecodingError) -> Int64? {
    try argument(.integer, for: columnType).map(library.pointee.value_int64)
  }

  mutating func decode(_ columnType: String.Type) throws(QueryDecodingError) -> String? {
    // A zero-length text value has no buffer behind it, which is not the same as SQL NULL.
    try argument(.text, for: columnType)
      .map { library.pointee.value_text($0).map(String.init(cString:)) ?? "" }
  }

  mutating func decode(_ columnType: Bool.Type) throws(QueryDecodingError) -> Bool? {
    try decode(Int64.self).map { $0 != 0 }
  }

  mutating func decode(_ columnType: Int.Type) throws(QueryDecodingError) -> Int? {
    guard let value = try decode(Int64.self) else { return nil }
    // `Int` is 32 bits wide on arm64_32, so a wider value is reported rather than trapped.
    guard let value = Int(exactly: value) else {
      throw QueryDecodingError.other(OrbitDatabaseIntegerOverflowError(value: value))
    }
    return value
  }

  mutating func decode(_ columnType: UInt64.Type) throws(QueryDecodingError) -> UInt64? {
    guard let value = try decode(Int64.self) else { return nil }
    guard value >= 0 else {
      throw QueryDecodingError.other(OrbitDatabaseIntegerOverflowError(value: value))
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
      throw QueryDecodingError.other(InvalidOrbitDatabaseUUIDError())
    }
    return uuid
  }
}

struct MissingDatabaseFunctionArgumentError: Error, CustomStringConvertible {
  let index: Int

  var description: String {
    "The database function was called without an argument at index \(index)."
  }
}

extension QueryBinding {
  // The table's result entry points copy what they are handed, so nothing here has to outlive the
  // call the way `SQLITE_TRANSIENT` would otherwise demand.
  func result(_ context: OpaquePointer?, library: UnsafePointer<SQLiteLibrary>) {
    let library = library.pointee
    switch self {
    case .blob(let blob):
      let bytes = Array(blob)
      bytes.withUnsafeBytes { library.result_blob(context, $0.baseAddress, Int32($0.count)) }
    case .bool(let bool):
      library.result_int64(context, bool ? 1 : 0)
    case .date(let date):
      date.orbitISO8601String.withCString { library.result_text(context, $0, -1) }
    case .double(let double):
      library.result_double(context, double)
    case .int(let int):
      library.result_int64(context, int)
    case .null:
      library.result_null(context)
    case .text(let text):
      text.withCString { library.result_text(context, $0, -1) }
    case .uint(let uint) where uint <= UInt64(Int64.max):
      library.result_int64(context, Int64(uint))
    case .uint(let uint):
      "Unsigned integer \(uint) overflows Int64.max"
        .withCString { library.result_error(context, $0, -1) }
    case .uuid(let uuid):
      uuid.uuidString.lowercased().withCString { library.result_text(context, $0, -1) }
    case .invalid(let error):
      "\(error.underlyingError)".withCString { library.result_error(context, $0, -1) }
    }
  }
}
