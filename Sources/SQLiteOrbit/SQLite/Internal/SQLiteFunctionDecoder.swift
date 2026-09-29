#if StructuredQueries
  import StructuredQueriesSQLite
  import _SQLiteOrbitFoundation

  struct SQLiteFunctionDecoder: QueryDecoder {
    let argumentCount: Int32
    let arguments: UnsafeMutablePointer<OpaquePointer?>?
    let api: SQLiteLibrary.FunctionCallbacks.Argument
    var currentIndex: Int32 = 0

    init(_ arguments: borrowing SQLiteFunctionArguments) {
      self.argumentCount = arguments.rawCount
      self.arguments = arguments.values
      self.api = arguments.api
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
      switch SQLiteColumnType(rawValue: api.type(value)) {
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
      guard let blob = api.blob(value) else { return [] }
      let count = Int(api.byteCount(value))
      return [UInt8](UnsafeRawBufferPointer(start: blob, count: count))
    }

    mutating func decode(_ columnType: Double.Type) throws(QueryDecodingError) -> Double? {
      try argument(.float, for: columnType).map(api.double)
    }

    mutating func decode(_ columnType: Int64.Type) throws(QueryDecodingError) -> Int64? {
      try argument(.integer, for: columnType).map(api.int64)
    }

    mutating func decode(_ columnType: String.Type) throws(QueryDecodingError) -> String? {
      guard let value = try argument(.text, for: columnType) else { return nil }
      // SQLite strings may contain NUL bytes, so they cannot be decoded as C strings. Ask for the
      // bytes before their count, which is the order SQLite documents as safe after conversion.
      guard let text = api.text(value) else { return "" }
      let count = Int(api.byteCount(value))
      return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
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
#endif
