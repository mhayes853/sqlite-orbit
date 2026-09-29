// Reading a value out of SQLite, spelled once for a result column and once for a function
// argument. Each is read in the storage class SQLite reports, so reading it never converts it, and
// text or a blob is asked for before its size, which is the order SQLite documents as safe: reading
// the size can convert the value, and a pointer taken before that conversion is the one it
// invalidates.

extension SQLiteLibrary.Columns {
  // The value of a column in the storage class SQLite holds it in.
  func value(_ statement: OpaquePointer, at column: Int32) -> OrbitDatabaseValue {
    switch SQLiteColumnType(rawValue: type(statement, column)) {
    case .integer: .integer(int64(statement, column))
    case .float: .real(double(statement, column))
    case .text: .text(textValue(statement, at: column))
    case .blob: .blob(blobValue(statement, at: column))
    default: .null
    }
  }

  // A column's text, which SQLite may hold with NUL bytes in it, so it is never read as a C
  // string.
  @inlinable
  func textValue(_ statement: OpaquePointer, at column: Int32) -> String {
    guard let text = text(statement, column) else { return "" }
    let byteCount = Int(self.byteCount(statement, column))
    guard byteCount > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self)
  }

  // A column's bytes. A zero-length blob has no buffer to point at.
  @inlinable
  func blobValue(_ statement: OpaquePointer, at column: Int32) -> [UInt8] {
    guard let bytes = blob(statement, column) else { return [] }
    let byteCount = Int(self.byteCount(statement, column))
    guard byteCount > 0 else { return [] }
    return [UInt8](UnsafeRawBufferPointer(start: bytes, count: byteCount))
  }

  // Whether a column's name is `name`, compared byte for byte against the name SQLite holds, so
  // nothing is allocated to find a column by its name.
  func hasName(_ name: String, _ statement: OpaquePointer, at column: Int32) -> Bool {
    guard let columnName = self.name(statement, column) else { return name.isEmpty }
    var character = columnName
    for byte in name.utf8 {
      guard UInt8(bitPattern: character.pointee) == byte, byte != 0 else { return false }
      character += 1
    }
    return character.pointee == 0
  }
}

extension SQLiteLibrary.FunctionCallbacks.Argument {
  // The value of a function argument in the storage class SQLite holds it in.
  func value(_ argument: OpaquePointer?) -> OrbitDatabaseValue {
    switch SQLiteColumnType(rawValue: type(argument)) {
    case .integer:
      return .integer(int64(argument))
    case .float:
      return .real(double(argument))
    case .text:
      guard let text = text(argument) else { return .text("") }
      let byteCount = Int(self.byteCount(argument))
      return .text(
        String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self)
      )
    case .blob:
      guard let bytes = blob(argument) else { return .blob([]) }
      let byteCount = Int(self.byteCount(argument))
      return .blob([UInt8](UnsafeRawBufferPointer(start: bytes, count: byteCount)))
    default:
      return .null
    }
  }
}
