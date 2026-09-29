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

    // Reads the argument the decoder is standing on and steps past it when it is SQL NULL or
    // `decoded` accepts it. Any other value is a type mismatch, which leaves the decoder where it
    // is.
    private mutating func decodeArgument<Value>(
      _ columnType: Any.Type,
      _ decoded: (OrbitDatabaseValue) -> Value?
    ) throws(QueryDecodingError) -> Value? {
      guard currentIndex < argumentCount else {
        throw QueryDecodingError.other(
          MissingDatabaseFunctionArgumentError(index: Int(currentIndex))
        )
      }
      let value = api.value(arguments?[Int(currentIndex)])
      if case .null = value {
        currentIndex += 1
        return nil
      }
      guard let decodedValue = decoded(value) else {
        throw QueryDecodingError.typeMismatch(columnType)
      }
      currentIndex += 1
      return decodedValue
    }

    mutating func decode(_ columnType: [UInt8].Type) throws(QueryDecodingError) -> [UInt8]? {
      try decodeArgument(columnType, \.blobValue)
    }

    mutating func decode(_ columnType: Double.Type) throws(QueryDecodingError) -> Double? {
      // Not `realValue`, which would read an integer as a real.
      try decodeArgument(columnType) { value in
        guard case .real(let real) = value else { return nil }
        return real
      }
    }

    mutating func decode(_ columnType: Int64.Type) throws(QueryDecodingError) -> Int64? {
      try decodeArgument(columnType, \.integerValue)
    }

    mutating func decode(_ columnType: String.Type) throws(QueryDecodingError) -> String? {
      try decodeArgument(columnType, \.textValue)
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
