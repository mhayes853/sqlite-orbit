import Foundation
import StructuredQueries

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
    switch library.pointee.column.type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.blob.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch([UInt8].self)
    }
    defer { currentIndex += 1 }
    // SQLite asks for the value before its size: reading the size can convert the value, and a
    // pointer taken before that conversion is the one it invalidates.
    guard let bytes = library.pointee.column.blob(statement, currentIndex) else { return [] }
    let byteCount = Int(library.pointee.column.byteCount(statement, currentIndex))
    guard byteCount > 0 else { return [] }
    return [UInt8](UnsafeRawBufferPointer(start: bytes, count: byteCount))
  }

  @inlinable
  mutating func decode(_ columnType: Double.Type) throws(QueryDecodingError) -> Double? {
    switch library.pointee.column.type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.float.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch(Double.self)
    }
    defer { currentIndex += 1 }
    return library.pointee.column.double(statement, currentIndex)
  }

  @inlinable
  mutating func decode(_ columnType: Int64.Type) throws(QueryDecodingError) -> Int64? {
    switch library.pointee.column.type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.integer.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch(Int64.self)
    }
    defer { currentIndex += 1 }
    return library.pointee.column.int64(statement, currentIndex)
  }

  @inlinable
  mutating func decode(_ columnType: UInt64.Type) throws(QueryDecodingError) -> UInt64? {
    guard let value = try decode(Int64.self) else { return nil }
    guard value >= 0 else {
      throw QueryDecodingError.other(OrbitDatabaseIntegerOverflowError(value: value))
    }
    return UInt64(value)
  }

  @inlinable
  mutating func decode(_ columnType: String.Type) throws(QueryDecodingError) -> String? {
    switch library.pointee.column.type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.text.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch(String.self)
    }
    defer { currentIndex += 1 }
    // The value is read before its size, which is the order SQLite documents as safe.
    guard let text = library.pointee.column.text(statement, currentIndex) else { return "" }
    let byteCount = Int(library.pointee.column.byteCount(statement, currentIndex))
    guard byteCount > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self)
  }

  @inlinable
  mutating func decode(_ columnType: Bool.Type) throws(QueryDecodingError) -> Bool? {
    try decode(Int64.self).map { $0 != 0 }
  }

  @inlinable
  mutating func decode(_ columnType: Int.Type) throws(QueryDecodingError) -> Int? {
    guard let value = try decode(Int64.self) else { return nil }
    // `Int` is 32 bits wide on arm64_32, which is every Apple Watch this package supports, so a
    // rowid past two billion would trap rather than be reported.
    guard let value = Int(exactly: value) else {
      throw QueryDecodingError.other(OrbitDatabaseIntegerOverflowError(value: value))
    }
    return value
  }

  @inlinable
  mutating func decode(_ columnType: Date.Type) throws(QueryDecodingError) -> Date? {
    guard let value = try decode(String.self) else { return nil }
    do {
      return try Date(orbitISO8601String: value)
    } catch {
      throw QueryDecodingError.other(error)
    }
  }

  @inlinable
  mutating func decode(_ columnType: UUID.Type) throws(QueryDecodingError) -> UUID? {
    switch library.pointee.column.type(statement, currentIndex) {
    case SQLiteColumnType.null.rawValue:
      currentIndex += 1
      return nil
    case SQLiteColumnType.text.rawValue:
      break
    default:
      throw QueryDecodingError.typeMismatch(UUID.self)
    }
    defer { currentIndex += 1 }
    guard let text = library.pointee.column.text(statement, currentIndex) else {
      throw QueryDecodingError.other(InvalidOrbitDatabaseUUIDError())
    }
    let byteCount = Int(library.pointee.column.byteCount(statement, currentIndex))
    let utf8 = UnsafeBufferPointer(start: text, count: byteCount)
    if let uuid = UUID(orbitUTF8: utf8) {
      return uuid
    }
    guard let uuid = UUID(uuidString: String(decoding: utf8, as: UTF8.self)) else {
      throw QueryDecodingError.other(InvalidOrbitDatabaseUUIDError())
    }
    return uuid
  }
}

extension SQLiteRowDecoder {
  @usableFromInline
  func describe(_ error: QueryDecodingError) -> any Error {
    switch error {
    case .missingRequiredColumn:
      return OrbitDatabaseColumnDecodingError(
        library: library,
        statement: statement,
        columnIndex: currentIndex - 1,
        reason: "to not be NULL"
      )
    case .typeMismatch(let columnType):
      return OrbitDatabaseColumnDecodingError(
        library: library,
        statement: statement,
        columnIndex: currentIndex,
        reason:
          "to decode \(columnType), but found "
          + orbitStorageClassName(library.pointee.column.type(statement, currentIndex))
      )
    case .other(let error):
      return error
    }
  }
}

/// A decoding failure, reported against the column it happened on.
///
/// SQLite is untyped enough that a schema change or a hand-written `SELECT` can quietly hand a
/// column back in the wrong storage class. This names which column it was.
///
/// ```swift
/// do {
///   _ = try await database.read { transaction in
///     try transaction.fetchAll(#sql("SELECT id, title FROM reminders", as: (Int, Int).self))
///   }
/// } catch let error as OrbitDatabaseColumnDecodingError {
///   print(error.columnIndex, error.columnName, error.reason)
/// }
/// ```
public struct OrbitDatabaseColumnDecodingError: Error, CustomStringConvertible {
  /// The zero-based position of the column in the result row.
  public let columnIndex: Int

  /// The column's name, or `"?"` when SQLite had none for it.
  public let columnName: String

  /// What the decoder expected, phrased to follow "Expected column N (name) ".
  public let reason: String

  /// The SQL of the statement that produced the row.
  public let sql: String

  @usableFromInline
  init(
    library: UnsafePointer<SQLiteLibrary>,
    statement: OpaquePointer,
    columnIndex: Int32,
    reason: String
  ) {
    self.columnIndex = Int(columnIndex)
    self.columnName =
      library.pointee.column.name(statement, columnIndex).map(String.init(cString:)) ?? "?"
    self.reason = reason
    self.sql = library.pointee.statement.sql(statement).map(String.init(cString:)) ?? ""
  }

  /// The column, its name, what was expected of it, and the SQL that produced it.
  public var description: String {
    """
    Expected column \(columnIndex) (\(columnName.debugDescription)) \(reason).

    \(sql)
    """
  }
}

@usableFromInline
func orbitStorageClassName(_ columnType: Int32) -> String {
  switch SQLiteColumnType(rawValue: columnType) {
  case .blob: "BLOB"
  case .float: "REAL"
  case .integer: "INTEGER"
  case .null: "NULL"
  case .text: "TEXT"
  default: "unknown"
  }
}
