func bind(
  _ sql: SQL,
  to statement: OpaquePointer,
  library: UnsafePointer<SQLiteLibrary>
) throws {
  if let failure = sql.bindingFailure {
    throw failure.error
  }
  for (offset, value) in sql.bindings.enumerated() {
    try bind(value, to: statement, at: Int32(offset + 1), library: library)
  }
}

private func bind(
  _ value: OrbitDatabaseValue,
  to statement: OpaquePointer,
  at index: Int32,
  library: UnsafePointer<SQLiteLibrary>
) throws {
  let code: Int32
  switch value {
  case .blob(let bytes):
    code = bytes.withUnsafeBytes { buffer in
      // A null pointer binds SQL NULL, so an empty blob needs a pointer that is merely unread.
      guard let baseAddress = buffer.baseAddress else {
        var empty: UInt8 = 0
        return withUnsafeBytes(of: &empty) {
          library.pointee.bindings.blob(statement, index, $0.baseAddress, 0)
        }
      }
      return library.pointee.bindings.blob(statement, index, baseAddress, Int32(buffer.count))
    }
  case .real(let double):
    code = library.pointee.bindings.double(statement, index, double)
  case .integer(let integer):
    code = library.pointee.bindings.int64(statement, index, integer)
  case .null:
    code = library.pointee.bindings.null(statement, index)
  case .text(let string):
    code = bindText(string, to: statement, at: index, library: library)
  }
  guard code == SQLiteResultCode.ok.rawValue else {
    throw SQLiteError(code: SQLiteResultCode(rawValue: code), message: "could not bind parameter")
  }
}

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
      return "".withCString { library.pointee.bindings.text(statement, index, $0, 0) }
    }
    return baseAddress.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
      library.pointee.bindings.text(statement, index, $0, Int32(buffer.count))
    }
  }
}

@usableFromInline
struct OrbitDatabaseIntegerOverflowError<Value: Sendable>: Error {
  @usableFromInline
  let value: Value

  @usableFromInline
  init(value: Value) {
    self.value = value
  }
}

extension OrbitDatabaseIntegerOverflowError: CustomStringConvertible {
  @usableFromInline
  var description: String {
    Value.self == UInt64.self
      ? "Unsigned integer \(value) overflows Int64.max"
      : "Integer \(value) overflows the type it is decoded as"
  }
}
