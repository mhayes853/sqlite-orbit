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
    guard let maximumByteCount, bytes.count > maximumByteCount else { return bytes }
    return try encodeExactly(message.withFullDatabaseRegion)
  }

  private static func encodeExactly(_ message: OrbitIPCMessage) throws -> [UInt8] {
    let database = Array(message.databaseIdentifier.rawValue.utf8)
    guard let databaseCount = UInt16(exactly: database.count) else {
      throw OrbitIPCWireError.databaseIdentifierTooLong
    }

    var bytes: [UInt8] = [
      0x4F, 0x52, 0x42, 0x54,  // ORBT
      1,
      Self.kind(of: message),
      UInt8(truncatingIfNeeded: databaseCount >> 8),
      UInt8(truncatingIfNeeded: databaseCount)
    ]
    bytes.append(contentsOf: database)

    switch message {
    case .transactionDidCommit(let commit):
      try append(commit.region.ipcRepresentation, to: &bytes)
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

    switch bytes[5] {
    case 1:
      let region = try readRegion(from: bytes, at: &offset)
      guard offset == bytes.count else { throw OrbitIPCWireError.trailingBytes }
      return .transactionDidCommit(
        .init(databaseIdentifier: databaseIdentifier, region: region)
      )
    default:
      throw OrbitIPCWireError.unsupportedMessageKind(bytes[5])
    }
  }

  private static func append(
    _ representation: OrbitDatabaseRegion.IPCRepresentation,
    to bytes: inout [UInt8]
  ) throws {
    bytes.append(representation.includesUnspecifiedTables ? 1 : 0)
    try appendCount(representation.tables.count, to: &bytes)
    for table in representation.tables {
      try append(table.schema, to: &bytes)
      try append(table.name, to: &bytes)
      bytes.append(table.includesUnspecifiedColumns ? 1 : 0)
      try appendCount(table.columnExceptions.count, to: &bytes)
      for column in table.columnExceptions {
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
    var tables: [OrbitDatabaseRegion.IPCRepresentation.Table] = []
    var tableNames: Set<RegionTableName> = []
    tables.reserveCapacity(tableCount)

    for _ in 0..<tableCount {
      let schema = try readString(from: bytes, at: &offset)
      let name = try readString(from: bytes, at: &offset)
      guard tableNames.insert(RegionTableName(schema: schema, name: name)).inserted else {
        throw OrbitIPCWireError.duplicateRegionEntry
      }
      let includesUnspecifiedColumns = try readBoolean(from: bytes, at: &offset)
      let columnCount = try readCount(from: bytes, at: &offset)
      var columns: [String] = []
      var columnNames: Set<String> = []
      columns.reserveCapacity(columnCount)
      for _ in 0..<columnCount {
        let column = try readString(from: bytes, at: &offset)
        guard columnNames.insert(column.asciiLowercased).inserted else {
          throw OrbitIPCWireError.duplicateRegionEntry
        }
        columns.append(column)
      }
      tables.append(
        .init(
          schema: schema,
          name: name,
          includesUnspecifiedColumns: includesUnspecifiedColumns,
          columnExceptions: columns
        )
      )
    }

    return OrbitDatabaseRegion(
      ipcRepresentation: .init(
        includesUnspecifiedTables: includesUnspecifiedTables,
        tables: tables
      )
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
      .withUnsafeBufferPointer { String(validating: $0, as: UTF8.self) }
    guard let string else { throw OrbitIPCWireError.invalidUTF8 }
    return string
  }

  private static func kind(of message: OrbitIPCMessage) -> UInt8 {
    switch message {
    case .transactionDidCommit: 1
    }
  }

  private struct RegionTableName: Hashable {
    let schema: String
    let name: String

    func hash(into hasher: inout Hasher) {
      hasher.combine(schema.asciiLowercased)
      hasher.combine(name.asciiLowercased)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.schema.asciiLowercased == rhs.schema.asciiLowercased
        && lhs.name.asciiLowercased == rhs.name.asciiLowercased
    }
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
