extension OrbitDatabaseRegion {
  /// Returns a lossless binary representation, including table and column exclusions.
  ///
  /// Version 1 starts with a big-endian `UInt16` version and a flags byte whose low bit includes
  /// unspecified tables. An unsigned LEB128 string count precedes length-prefixed UTF-8 strings,
  /// followed by an unsigned LEB128 table count. Each table stores its schema and name indices,
  /// a flags byte whose low bit includes unspecified columns, and a count and list of column
  /// exception indices. All lengths, counts, and indices use minimal unsigned 64-bit LEB128.
  /// Reserved flag bits are zero. String indices are zero-based.
  ///
  /// Strings are deduplicated and ordered by UTF-8 bytes; tables are ordered by schema and name
  /// indices, and columns by their indices. Encoding preserves the region's stored identifier
  /// spellings and is independent of dictionary and set iteration order. Canonically equivalent
  /// Unicode spellings may compare equal as regions while producing different bytes.
  ///
  /// This format has no datagram size limit and never broadens a region to fit one.
  public func serialized() -> [UInt8] {
    // String equality folds canonically equivalent Unicode spellings; byte keys preserve them.
    var names = Set<[UInt8]>()
    for (table, region) in tableRegions {
      names.insert(Array(table.schema.rawValue.utf8))
      names.insert(Array(table.name.utf8))
      names.formUnion(region.exceptions.lazy.map { Array($0.utf8) })
    }
    let strings = names.sorted { $0.lexicographicallyPrecedes($1) }
    let indices = Dictionary(uniqueKeysWithValues: strings.enumerated().map { ($1, $0) })
    let indexedTables =
      tableRegions.map { table, region in
        (
          schema: indices[Array(table.schema.rawValue.utf8)]!,
          name: indices[Array(table.name.utf8)]!,
          includesColumns: region.includesUnspecifiedColumns,
          columns: region.exceptions.map { indices[Array($0.utf8)]! }.sorted()
        )
      }
      .sorted { ($0.schema, $0.name) < ($1.schema, $1.name) }

    var bytes: [UInt8] = [0, 1, includesUnspecifiedTables ? 1 : 0]
    OrbitRegionBinaryCoding.appendCount(strings.count, to: &bytes)
    for string in strings {
      OrbitRegionBinaryCoding.appendCount(string.count, to: &bytes)
      bytes.append(contentsOf: string)
    }
    OrbitRegionBinaryCoding.appendCount(indexedTables.count, to: &bytes)
    for table in indexedTables {
      OrbitRegionBinaryCoding.appendCount(table.schema, to: &bytes)
      OrbitRegionBinaryCoding.appendCount(table.name, to: &bytes)
      bytes.append(table.includesColumns ? 1 : 0)
      OrbitRegionBinaryCoding.appendCount(table.columns.count, to: &bytes)
      for column in table.columns { OrbitRegionBinaryCoding.appendCount(column, to: &bytes) }
    }
    return bytes
  }

  /// Decodes exactly one versioned binary region.
  ///
  /// Identifiers use the same ASCII case normalization as the region's other initializers.
  /// Decoding accepts unsorted entries and removes table entries matching the region's default.
  ///
  /// - Parameter bytes: A representation produced by ``serialized()``.
  /// - Throws: `DecodingError.dataCorrupted` for unsupported versions, reserved flags, invalid
  ///   UTF-8 or indices, duplicate table or column entries, invalid or overflowing integers,
  ///   truncated input, or trailing bytes.
  public init(serialized bytes: Span<UInt8>) throws {
    typealias Coding = OrbitRegionBinaryCoding
    guard bytes.count >= 2 else { throw Coding.error("Truncated region version") }
    let version = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    guard version == 1 else { throw Coding.error("Unsupported region version: \(version)") }
    var offset = 2
    let includesTables = try Coding.readFlag(bytes, at: &offset)
    let stringCount = try Coding.readCount(bytes, at: &offset)
    // Every string needs at least one length byte. Do not allocate from unchecked input counts.
    guard stringCount <= bytes.count - offset else { throw Coding.error("Truncated string table") }
    var strings: [String] = []
    for _ in 0..<stringCount {
      let length = try Coding.readCount(bytes, at: &offset)
      guard length <= bytes.count - offset else { throw Coding.error("Truncated string") }
      let string = bytes.extracting(offset..<(offset + length))
        .withUnsafeBufferPointer { buffer -> String? in
          // This round trip validates UTF-8 on all supported deployment targets.
          let string = String(decoding: buffer, as: UTF8.self)
          return string.utf8.elementsEqual(buffer) ? string : nil
        }
      guard let string else { throw Coding.error("Invalid UTF-8 identifier") }
      // Normalize each shared identifier once; later uses retain its string storage.
      strings.append(string.asciiLowercased)
      offset += length
    }

    let tableCount = try Coding.readCount(bytes, at: &offset)
    // Two indices, a flag, and a column count occupy at least four bytes per table.
    guard tableCount <= (bytes.count - offset) / 4 else { throw Coding.error("Truncated tables") }
    var tables: [TableIdentifier: TableRegion] = [:]
    for _ in 0..<tableCount {
      let schema = try Coding.readString(bytes, at: &offset, strings: strings)
      let name = try Coding.readString(bytes, at: &offset, strings: strings)
      let table = TableIdentifier(schema: SQLiteSchemaName(schema), name: name)
      guard tables[table] == nil else { throw Coding.error("Duplicate table entry") }
      let includesColumns = try Coding.readFlag(bytes, at: &offset)
      let columnCount = try Coding.readCount(bytes, at: &offset)
      guard columnCount <= bytes.count - offset else { throw Coding.error("Truncated columns") }
      var columns = Set<String>()
      for _ in 0..<columnCount {
        let column = try Coding.readString(bytes, at: &offset, strings: strings).asciiLowercased
        guard columns.insert(column).inserted else { throw Coding.error("Duplicate column entry") }
      }
      tables[table] = TableRegion(includesUnspecifiedColumns: includesColumns, exceptions: columns)
    }
    guard offset == bytes.count else { throw Coding.error("Trailing region bytes") }
    self.init(includesUnspecifiedTables: includesTables, tableRegions: tables)
  }
}

extension OrbitDatabaseRegion: Codable {
  /// Encodes the versioned binary representation as a single byte array.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(serialized())
  }

  /// Decodes a byte array through the same version and validity checks as ``init(serialized:)``.
  public init(from decoder: any Decoder) throws {
    let bytes = try decoder.singleValueContainer().decode([UInt8].self)
    do {
      self = try bytes.withUnsafeBufferPointer {
        try Self(serialized: Span(_unsafeElements: $0))
      }
    } catch DecodingError.dataCorrupted(let context) {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: context.debugDescription)
      )
    }
  }
}

private enum OrbitRegionBinaryCoding {
  static func error(_ description: String) -> DecodingError {
    .dataCorrupted(.init(codingPath: [], debugDescription: description))
  }

  static func appendCount(_ count: Int, to bytes: inout [UInt8]) {
    var value = UInt64(count)
    while value >= 0x80 {
      bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
      value >>= 7
    }
    bytes.append(UInt8(value))
  }

  static func readByte(_ bytes: Span<UInt8>, at offset: inout Int) throws -> UInt8 {
    guard offset < bytes.count else { throw error("Truncated region") }
    defer { offset += 1 }
    return bytes[offset]
  }

  static func readFlag(_ bytes: Span<UInt8>, at offset: inout Int) throws -> Bool {
    switch try readByte(bytes, at: &offset) {
    case 0: false
    case 1: true
    default: throw error("Reserved region flag bits are set")
    }
  }

  static func readCount(_ bytes: Span<UInt8>, at offset: inout Int) throws -> Int {
    var value: UInt64 = 0
    for index in 0..<10 {
      let byte = try readByte(bytes, at: &offset)
      guard index < 9 || byte <= 1 else { throw error("Overflowing region integer") }
      value |= UInt64(byte & 0x7F) << (index * 7)
      if byte & 0x80 == 0 {
        guard index == 0 || byte != 0 else { throw error("Nonminimal region integer") }
        guard let count = Int(exactly: value) else {
          throw error("Region integer exceeds platform limits")
        }
        return count
      }
    }
    throw error("Overflowing region integer")
  }

  static func readString(
    _ bytes: Span<UInt8>,
    at offset: inout Int,
    strings: [String]
  ) throws -> String {
    let index = try readCount(bytes, at: &offset)
    guard index < strings.count else { throw error("Region string index is out of range") }
    return strings[index]
  }
}
