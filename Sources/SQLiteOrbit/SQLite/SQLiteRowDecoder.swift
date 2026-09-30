#if StructuredQueries
  import StructuredQueriesSQLite
  import _SQLiteOrbitFoundation

  extension SQLiteRow: OrbitDatabaseStructuredRow {
    /// Decodes the next column of this row.
    ///
    /// - Parameter type: The value to decode.
    /// - Returns: The decoded value.
    /// - Throws: ``OrbitDatabaseColumnDecodingError`` naming the column when its storage class or
    ///   contents cannot produce `type`.
    @inlinable
    @_lifetime(self: copy self)
    public mutating func decode<Value: QueryRepresentable>(
      _ type: Value.Type
    ) throws -> Value.QueryOutput {
      do {
        return try Value(decoder: &decoder).queryOutput
      } catch let error as QueryDecodingError {
        throw decoder.describe(error)
      }
    }

    /// Decodes the next columns of this row as a tuple, one column per value.
    ///
    /// - Parameter type: The tuple of values to decode.
    /// - Returns: The decoded values.
    /// - Throws: ``OrbitDatabaseColumnDecodingError`` naming the column that could not be decoded.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @inlinable
    @_lifetime(self: copy self)
    public mutating func decode<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> (repeat (each Value).QueryOutput) {
      do {
        return try decoder.decodeColumns((repeat each Value).self)
      } catch let error as QueryDecodingError {
        throw decoder.describe(error)
      }
    }
  }

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

    /// Checks the storage class of the column the decoder is standing on and steps past it.
    ///
    /// - Parameters:
    ///   - expected: The storage class the value has to be in.
    ///   - columnType: The type being decoded, which names the type mismatch.
    /// - Returns: The column the value is in, or `nil` when the value is SQL NULL.
    /// - Throws: ``QueryDecodingError/typeMismatch(_:)`` for any other storage class, without
    ///   stepping past the column, so the error can name the one that did not decode.
    @inlinable
    mutating func column(
      _ expected: SQLiteColumnType,
      _ columnType: Any.Type
    ) throws(QueryDecodingError) -> Int32? {
      let column = currentIndex
      switch library.pointee.columns.type(statement, column) {
      case SQLiteColumnType.null.rawValue:
        currentIndex += 1
        return nil
      case expected.rawValue:
        currentIndex += 1
        return column
      default:
        throw QueryDecodingError.typeMismatch(columnType)
      }
    }

    @inlinable
    mutating func decode(_ columnType: [UInt8].Type) throws(QueryDecodingError) -> [UInt8]? {
      guard let column = try column(.blob, columnType) else { return nil }
      return library.pointee.columns.blobValue(statement, at: column)
    }

    @inlinable
    mutating func decode(_ columnType: Double.Type) throws(QueryDecodingError) -> Double? {
      guard let column = try column(.float, columnType) else { return nil }
      return library.pointee.columns.double(statement, column)
    }

    @inlinable
    mutating func decode(_ columnType: Int64.Type) throws(QueryDecodingError) -> Int64? {
      guard let column = try column(.integer, columnType) else { return nil }
      return library.pointee.columns.int64(statement, column)
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
      guard let column = try column(.text, columnType) else { return nil }
      return library.pointee.columns.textValue(statement, at: column)
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
      guard let column = try column(.text, columnType) else { return nil }
      guard let text = library.pointee.columns.text(statement, column) else {
        throw QueryDecodingError.other(InvalidOrbitDatabaseUUIDError())
      }
      let byteCount = Int(library.pointee.columns.byteCount(statement, column))
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
            + orbitStorageClassName(library.pointee.columns.type(statement, currentIndex))
        )
      case .other(let error):
        return error
      }
    }
  }

  extension OrbitDatabaseColumnDecodingError {
    @usableFromInline
    init(
      library: UnsafePointer<SQLiteLibrary>,
      statement: OpaquePointer,
      columnIndex: Int32,
      reason: String
    ) {
      self.init(
        columnIndex: Int(columnIndex),
        columnName:
          library.pointee.columns.name(statement, columnIndex).map(String.init(cString:)) ?? "?",
        reason: reason,
        sql: library.pointee.statements.inspection.sql(statement).map(String.init(cString:))
      )
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
#endif
