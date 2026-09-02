import Foundation
import StructuredQueries

/// Decodes Structured Queries values straight out of SQLite's current result row.
///
/// Values are read through the connection's library table rather than a linked SQLite, and no
/// intermediate boxed value is allocated per column.
@usableFromInline
struct SQLiteRowDecoder: QueryDecoder {
  @usableFromInline
  let library: UnsafePointer<SQLiteLibrary>

  @usableFromInline
  let statement: OpaquePointer

  @usableFromInline
  var currentIndex: Int32 = 0

  @usableFromInline
  init(library: UnsafePointer<SQLiteLibrary>, statement: OpaquePointer) {
    self.library = library
    self.statement = statement
  }

  @inlinable
  mutating func decode(_ columnType: [UInt8].Type) throws(QueryDecodingError) -> [UInt8]? {
    switch library.pointee.column_type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.blob.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch([UInt8].self)
    }
    defer { currentIndex += 1 }
    let byteCount = Int(library.pointee.column_bytes(statement, currentIndex))
    guard byteCount > 0, let bytes = library.pointee.column_blob(statement, currentIndex) else {
      return []
    }
    return [UInt8](UnsafeRawBufferPointer(start: bytes, count: byteCount))
  }

  @inlinable
  mutating func decode(_ columnType: Double.Type) throws(QueryDecodingError) -> Double? {
    switch library.pointee.column_type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.float.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch(Double.self)
    }
    defer { currentIndex += 1 }
    return library.pointee.column_double(statement, currentIndex)
  }

  @inlinable
  mutating func decode(_ columnType: Int64.Type) throws(QueryDecodingError) -> Int64? {
    switch library.pointee.column_type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.integer.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch(Int64.self)
    }
    defer { currentIndex += 1 }
    return library.pointee.column_int64(statement, currentIndex)
  }

  @inlinable
  mutating func decode(_ columnType: UInt64.Type) throws(QueryDecodingError) -> UInt64? {
    guard let value = try decode(Int64.self) else { return nil }
    guard value >= 0 else {
      throw QueryDecodingError.other(DatabaseIntegerOverflowError(value: value))
    }
    return UInt64(value)
  }

  @inlinable
  mutating func decode(_ columnType: String.Type) throws(QueryDecodingError) -> String? {
    switch library.pointee.column_type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.text.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch(String.self)
    }
    defer { currentIndex += 1 }
    let byteCount = Int(library.pointee.column_bytes(statement, currentIndex))
    guard byteCount > 0, let text = library.pointee.column_text(statement, currentIndex) else {
      return ""
    }
    return String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self)
  }

  @inlinable
  mutating func decode(_ columnType: Bool.Type) throws(QueryDecodingError) -> Bool? {
    try decode(Int64.self).map { $0 != 0 }
  }

  @inlinable
  mutating func decode(_ columnType: Int.Type) throws(QueryDecodingError) -> Int? {
    try decode(Int64.self).map(Int.init)
  }

  @inlinable
  mutating func decode(_ columnType: Date.Type) throws(QueryDecodingError) -> Date? {
    guard let value = try decode(String.self) else { return nil }
    do {
      return try Date(sqliteCrossISO8601String: value)
    } catch {
      throw QueryDecodingError.other(error)
    }
  }

  @inlinable
  mutating func decode(_ columnType: UUID.Type) throws(QueryDecodingError) -> UUID? {
    switch library.pointee.column_type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.text.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch(UUID.self)
    }
    defer { currentIndex += 1 }
    let byteCount = Int(library.pointee.column_bytes(statement, currentIndex))
    guard let text = library.pointee.column_text(statement, currentIndex) else {
      throw QueryDecodingError.other(InvalidDatabaseUUIDError())
    }
    let utf8 = UnsafeBufferPointer(start: text, count: byteCount)
    if let uuid = UUID(sqliteCrossUTF8: utf8) {
      return uuid
    }
    guard let uuid = UUID(uuidString: String(decoding: utf8, as: UTF8.self)) else {
      throw QueryDecodingError.other(InvalidDatabaseUUIDError())
    }
    return uuid
  }
}
