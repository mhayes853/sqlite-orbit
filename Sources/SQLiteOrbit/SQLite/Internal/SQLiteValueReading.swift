// Reading a function argument's value out of SQLite, the way `SQLiteRowColumnReader` reads a
// result column's. Each is read in the storage class SQLite reports, so reading it never converts
// it, and text or a blob is asked for before its size, which is the order SQLite documents as
// safe: reading the size can convert the value, and a pointer taken before that conversion is the
// one it invalidates.

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
