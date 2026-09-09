enum OrbitIPCWireError: Error, Equatable {
  case databaseIdentifierTooLong
  case duplicateRegionEntry
  case invalidBoolean
  case invalidMagic
  case invalidUTF8
  case regionTooLarge
  case trailingBytes
  case truncated
  case unsupportedMessageKind(UInt8)
  case unsupportedProtocolVersion(UInt8)
}

enum OrbitIPCWireProtocol {
  static func encode(
    _ message: OrbitIPCMessage,
    maximumByteCount: Int? = nil
  ) throws -> [UInt8] {
    let bytes: [UInt8]
    do {
      bytes = try encodeExactly(message)
    } catch OrbitIPCWireError.regionTooLarge {
      return try encodeExactly(message.withFullDatabaseRegion)
    }
    if let maximumByteCount, bytes.count > maximumByteCount {
      return try encodeExactly(message.withFullDatabaseRegion)
    }
    return bytes
  }

  private static func encodeExactly(_ message: OrbitIPCMessage) throws -> [UInt8] {
    let database = Array(message.databaseIdentifier.rawValue.utf8)
    guard let databaseCount = UInt16(exactly: database.count) else {
      throw OrbitIPCWireError.databaseIdentifierTooLong
    }

    var bytes: [UInt8] = [
      0x4F, 0x52, 0x42, 0x54,  // ORBT
      1,
      1,
      UInt8(truncatingIfNeeded: databaseCount >> 8),
      UInt8(truncatingIfNeeded: databaseCount)
    ]
    bytes.append(contentsOf: database)

    switch message {
    case .transactionDidCommit(let commit):
      try append(commit.region, to: &bytes)
    }
    return bytes
  }

  static func decode(_ bytes: Span<UInt8>) throws -> OrbitIPCMessage {
    guard bytes.count >= 8 else { throw OrbitIPCWireError.truncated }
    guard bytes[0] == 0x4F, bytes[1] == 0x52, bytes[2] == 0x42, bytes[3] == 0x54 else {
      throw OrbitIPCWireError.invalidMagic
    }
    guard bytes[4] == 1 else {
      throw OrbitIPCWireError.unsupportedProtocolVersion(bytes[4])
    }

    var offset = 6
    let database = try readString(from: bytes, at: &offset)
    let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: database)
    guard bytes[5] == 1 else { throw OrbitIPCWireError.unsupportedMessageKind(bytes[5]) }
    let region = try readRegion(from: bytes, at: &offset)
    guard offset == bytes.count else { throw OrbitIPCWireError.trailingBytes }
    return .transactionDidCommit(
      .init(databaseIdentifier: databaseIdentifier, region: region)
    )
  }

  private static func append(
    _ region: OrbitDatabaseRegion,
    to bytes: inout [UInt8]
  ) throws {
    bytes.append(region.includesUnspecifiedTables ? 1 : 0)
    let tables = region.tableRegions.sorted {
      ($0.key.schema.rawValue, $0.key.name) < ($1.key.schema.rawValue, $1.key.name)
    }
    try appendCount(tables.count, to: &bytes)
    for (table, tableRegion) in tables {
      try append(table.schema.rawValue, to: &bytes)
      try append(table.name, to: &bytes)
      bytes.append(tableRegion.includesUnspecifiedColumns ? 1 : 0)
      try appendCount(tableRegion.exceptions.count, to: &bytes)
      for column in tableRegion.exceptions.sorted() {
        try append(column, to: &bytes)
      }
    }
  }

  private static func append(_ string: String, to bytes: inout [UInt8]) throws {
    let value = Array(string.utf8)
    try appendCount(value.count, to: &bytes)
    bytes.append(contentsOf: value)
  }

  private static func appendCount(_ count: Int, to bytes: inout [UInt8]) throws {
    guard let count = UInt16(exactly: count) else { throw OrbitIPCWireError.regionTooLarge }
    bytes.append(UInt8(truncatingIfNeeded: count >> 8))
    bytes.append(UInt8(truncatingIfNeeded: count))
  }

  private static func readRegion(
    from bytes: Span<UInt8>,
    at offset: inout Int
  ) throws -> OrbitDatabaseRegion {
    let includesUnspecifiedTables = try readBoolean(from: bytes, at: &offset)
    let tableCount = try readCount(from: bytes, at: &offset)
    var tables: [OrbitDatabaseRegion.TableIdentifier: OrbitDatabaseRegion.TableRegion] = [:]
    tables.reserveCapacity(tableCount)

    for _ in 0..<tableCount {
      let schema = try readString(from: bytes, at: &offset)
      let name = try readString(from: bytes, at: &offset)
      let table = OrbitDatabaseRegion.TableIdentifier(
        schema: SQLiteSchemaName(schema),
        name: name
      )
      guard tables[table] == nil else {
        throw OrbitIPCWireError.duplicateRegionEntry
      }
      let includesUnspecifiedColumns = try readBoolean(from: bytes, at: &offset)
      let columnCount = try readCount(from: bytes, at: &offset)
      var columns: Set<String> = []
      columns.reserveCapacity(columnCount)
      for _ in 0..<columnCount {
        let column = try readString(from: bytes, at: &offset).asciiLowercased
        guard columns.insert(column).inserted else {
          throw OrbitIPCWireError.duplicateRegionEntry
        }
      }
      tables[table] = OrbitDatabaseRegion.TableRegion(
        includesUnspecifiedColumns: includesUnspecifiedColumns,
        exceptions: columns
      )
    }

    return OrbitDatabaseRegion(
      includesUnspecifiedTables: includesUnspecifiedTables,
      tableRegions: tables
    )
  }

  private static func readBoolean(from bytes: Span<UInt8>, at offset: inout Int) throws -> Bool {
    guard offset < bytes.count else { throw OrbitIPCWireError.truncated }
    defer { offset += 1 }
    switch bytes[offset] {
    case 0: return false
    case 1: return true
    default: throw OrbitIPCWireError.invalidBoolean
    }
  }

  private static func readCount(from bytes: Span<UInt8>, at offset: inout Int) throws -> Int {
    guard offset <= bytes.count - 2 else { throw OrbitIPCWireError.truncated }
    defer { offset += 2 }
    return Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
  }

  private static func readString(from bytes: Span<UInt8>, at offset: inout Int) throws -> String {
    let count = try readCount(from: bytes, at: &offset)
    guard count <= bytes.count - offset else { throw OrbitIPCWireError.truncated }
    defer { offset += count }
    let string = bytes.extracting(offset..<(offset + count))
      .withUnsafeBufferPointer { buffer -> String? in
        // `String(decoding:as:)` repairs malformed sequences rather than rejecting them, so the
        // round trip is what rejects them. `String(validating:as:)` says this in one call, but
        // only on platforms newer than the ones this package supports.
        let decoded = String(decoding: buffer, as: UTF8.self)
        return decoded.utf8.elementsEqual(buffer) ? decoded : nil
      }
    guard let string else { throw OrbitIPCWireError.invalidUTF8 }
    return string
  }
}

extension OrbitIPCMessage {
  fileprivate var withFullDatabaseRegion: Self {
    switch self {
    case .transactionDidCommit(let commit):
      .transactionDidCommit(
        .init(databaseIdentifier: commit.databaseIdentifier, region: .fullDatabase)
      )
    }
  }
}
