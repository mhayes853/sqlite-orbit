enum UnixDatagramWireError: Error, Equatable {
  case databaseIdentifierTooLong
  case datagramTooLarge
  case duplicateRegionEntry
  case emptyBatch
  case invalidFlags
  case invalidMagic
  case invalidUTF8
  case payloadLengthMismatch
  case regionTooLarge
  case stringIndexOutOfRange
  case trailingBytes
  case truncated
  case unsupportedProtocolVersion(UInt8)
}

/// The datagram format peers exchange: a batch of entries sharing one table of strings.
///
/// Every integer is big-endian.
///
/// ```
/// Header (8): magic "ORBT" | version u8 = 1 | flags u8 = 0 | entryCount u16 (>= 1)
/// String table: stringCount u16, then [length u16, UTF-8 bytes] × stringCount
/// Entries × entryCount, in commit order: kind u8 | payloadLength u16 | payload
/// ```
///
/// A `transactionDidCommit` entry (kind 1) carries the database as a string index, then its
/// region: flags u8 (bit 0 includes unspecified tables) | tableCount u16, and per table a schema
/// index u16 | name index u16 | flags u8 (bit 0 includes unspecified columns) | columnCount u16 |
/// a column index u16 per column. A decoder skips an entry of a kind it does not know by its
/// length, and rejects the whole datagram over anything else it cannot read.
///
/// A marker, which advertises the region an endpoint subscribes to, is a string table followed by
/// one region.
enum UnixDatagramWireProtocol {
  /// Encodes `message` as a batch of one.
  ///
  /// - Parameters:
  ///   - message: The message to encode.
  ///   - maximumByteCount: The longest datagram allowed. A message whose region makes it longer is
  ///     broadened to the full database.
  /// - Returns: The datagram.
  static func encode(
    _ message: OrbitIPCMessage,
    maximumByteCount: Int = Int(UInt16.max)
  ) throws -> [UInt8] {
    var batch = UnixDatagramWireBatch()
    batch.append(try UnixDatagramWireEntry(message, fittingIn: maximumByteCount))
    return batch.encoded()
  }

  /// Decodes every entry of a datagram this decoder knows the kind of.
  ///
  /// - Parameter bytes: The datagram.
  /// - Returns: The entries' messages, in the order they were encoded.
  /// - Throws: A ``UnixDatagramWireError`` if any part of the datagram is malformed, in which case
  ///   none of it is delivered.
  static func decode(_ bytes: Span<UInt8>) throws -> [OrbitIPCMessage] {
    guard bytes.count >= 8 else { throw UnixDatagramWireError.truncated }
    guard bytes[0] == 0x4F, bytes[1] == 0x52, bytes[2] == 0x42, bytes[3] == 0x54 else {
      throw UnixDatagramWireError.invalidMagic
    }
    guard bytes[4] == 1 else {
      throw UnixDatagramWireError.unsupportedProtocolVersion(bytes[4])
    }
    guard bytes[5] == 0 else { throw UnixDatagramWireError.invalidFlags }
    var offset = 6
    let entryCount = try readCount(from: bytes, at: &offset)
    guard entryCount > 0 else { throw UnixDatagramWireError.emptyBatch }
    let strings = try readStringTable(from: bytes, at: &offset)

    var messages: [OrbitIPCMessage] = []
    for _ in 0..<entryCount {
      let kind = try readByte(from: bytes, at: &offset)
      let payloadCount = try readCount(from: bytes, at: &offset)
      guard payloadCount <= bytes.count - offset else { throw UnixDatagramWireError.truncated }
      let payload = bytes.extracting(offset..<(offset + payloadCount))
      offset += payloadCount
      guard kind == 1 else { continue }

      var payloadOffset = 0
      let database = try readString(from: payload, at: &payloadOffset, in: strings)
      let region = try readRegion(from: payload, at: &payloadOffset, strings: strings)
      guard payloadOffset == payload.count else {
        throw UnixDatagramWireError.payloadLengthMismatch
      }
      messages.append(
        .transactionDidCommit(
          .init(databaseIdentifier: OrbitDatabaseIdentifier(rawValue: database), region: region)
        )
      )
    }
    guard offset == bytes.count else { throw UnixDatagramWireError.trailingBytes }
    return messages
  }

  /// Encodes the region an endpoint advertises in a marker.
  ///
  /// A region too large to encode is advertised as the full database, which admits everything.
  static func encodeMarker(_ region: OrbitDatabaseRegion) -> [UInt8] {
    let strings = self.strings(in: region)
    guard strings.count <= UInt16.max, (try? byteCount(of: region)) != nil else {
      return encodeMarker(.fullDatabase)
    }
    var bytes: [UInt8] = []
    appendStringTable(strings, to: &bytes)
    appendRegion(
      region,
      to: &bytes,
      indices: Dictionary(uniqueKeysWithValues: strings.enumerated().map { ($1, $0) })
    )
    return bytes
  }

  /// Decodes the region a marker advertises.
  ///
  /// - Throws: A ``UnixDatagramWireError`` if the marker is malformed.
  static func decodeMarker(_ bytes: Span<UInt8>) throws -> OrbitDatabaseRegion {
    var offset = 0
    let strings = try readStringTable(from: bytes, at: &offset)
    let region = try readRegion(from: bytes, at: &offset, strings: strings)
    guard offset == bytes.count else { throw UnixDatagramWireError.trailingBytes }
    return region
  }

  // MARK: - Strings

  /// The strings `region` refers to, each once, in the order its encoding first refers to them,
  /// after those in `preceding`.
  static func strings(in region: OrbitDatabaseRegion, after preceding: [String] = []) -> [String] {
    var seen = Set(preceding)
    var strings = preceding
    for (table, tableRegion) in sortedTables(of: region) {
      for string in [table.schema.rawValue, table.name] + tableRegion.exceptions.sorted()
      where seen.insert(string).inserted {
        strings.append(string)
      }
    }
    return strings
  }

  static func appendStringTable(_ strings: [String], to bytes: inout [UInt8]) {
    appendCount(strings.count, to: &bytes)
    for string in strings {
      appendCount(string.utf8.count, to: &bytes)
      bytes.append(contentsOf: string.utf8)
    }
  }

  /// Reads a string table, validating each string's UTF-8 once.
  private static func readStringTable(
    from bytes: Span<UInt8>,
    at offset: inout Int
  ) throws -> [String] {
    var strings: [String] = []
    for _ in 0..<(try readCount(from: bytes, at: &offset)) {
      let length = try readCount(from: bytes, at: &offset)
      guard length <= bytes.count - offset else { throw UnixDatagramWireError.truncated }
      let string = bytes.extracting(offset..<(offset + length))
        .withUnsafeBufferPointer { buffer -> String? in
          // `String(decoding:as:)` repairs malformed sequences rather than rejecting them, so the
          // round trip is what rejects them. `String(validating:as:)` says this in one call, but
          // only on platforms newer than the ones this package supports.
          let decoded = String(decoding: buffer, as: UTF8.self)
          return decoded.utf8.elementsEqual(buffer) ? decoded : nil
        }
      guard let string else { throw UnixDatagramWireError.invalidUTF8 }
      strings.append(string)
      offset += length
    }
    return strings
  }

  // MARK: - Regions

  /// The length of `region`'s encoding, which does not depend on the strings it refers to.
  ///
  /// - Throws: ``UnixDatagramWireError/regionTooLarge`` if a count or string does not fit in 16
  ///   bits.
  static func byteCount(of region: OrbitDatabaseRegion) throws -> Int {
    guard region.tableRegions.count <= UInt16.max else {
      throw UnixDatagramWireError.regionTooLarge
    }
    var byteCount = 3
    for (table, tableRegion) in region.tableRegions {
      guard tableRegion.exceptions.count <= UInt16.max,
        table.schema.rawValue.utf8.count <= UInt16.max,
        table.name.utf8.count <= UInt16.max,
        tableRegion.exceptions.allSatisfy({ $0.utf8.count <= UInt16.max })
      else { throw UnixDatagramWireError.regionTooLarge }
      byteCount += 7 + 2 * tableRegion.exceptions.count
    }
    return byteCount
  }

  /// Appends `region`, naming each string by its index in `indices`.
  static func appendRegion(
    _ region: OrbitDatabaseRegion,
    to bytes: inout [UInt8],
    indices: [String: Int]
  ) {
    bytes.append(region.includesUnspecifiedTables ? 1 : 0)
    let tables = sortedTables(of: region)
    appendCount(tables.count, to: &bytes)
    for (table, tableRegion) in tables {
      appendCount(indices[table.schema.rawValue]!, to: &bytes)
      appendCount(indices[table.name]!, to: &bytes)
      bytes.append(tableRegion.includesUnspecifiedColumns ? 1 : 0)
      appendCount(tableRegion.exceptions.count, to: &bytes)
      for column in tableRegion.exceptions.sorted() {
        appendCount(indices[column]!, to: &bytes)
      }
    }
  }

  /// Reads a region whose strings are indices into `strings`.
  private static func readRegion(
    from bytes: Span<UInt8>,
    at offset: inout Int,
    strings: [String]
  ) throws -> OrbitDatabaseRegion {
    let includesUnspecifiedTables = try readFlag(from: bytes, at: &offset)
    var tables: [OrbitDatabaseRegion.TableIdentifier: OrbitDatabaseRegion.TableRegion] = [:]
    for _ in 0..<(try readCount(from: bytes, at: &offset)) {
      let schema = try readString(from: bytes, at: &offset, in: strings)
      let name = try readString(from: bytes, at: &offset, in: strings)
      let table = OrbitDatabaseRegion.TableIdentifier(
        schema: SQLiteSchemaName(schema),
        name: name
      )
      guard tables[table] == nil else {
        throw UnixDatagramWireError.duplicateRegionEntry
      }
      let includesUnspecifiedColumns = try readFlag(from: bytes, at: &offset)
      var columns: Set<String> = []
      for _ in 0..<(try readCount(from: bytes, at: &offset)) {
        let column = try readString(from: bytes, at: &offset, in: strings).asciiLowercased
        guard columns.insert(column).inserted else {
          throw UnixDatagramWireError.duplicateRegionEntry
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

  private static func sortedTables(
    of region: OrbitDatabaseRegion
  ) -> [(key: OrbitDatabaseRegion.TableIdentifier, value: OrbitDatabaseRegion.TableRegion)] {
    region.tableRegions.sorted {
      ($0.key.schema.rawValue, $0.key.name) < ($1.key.schema.rawValue, $1.key.name)
    }
  }

  // MARK: - Primitives

  static func appendCount(_ count: Int, to bytes: inout [UInt8]) {
    let count = UInt16(count)
    bytes.append(UInt8(truncatingIfNeeded: count >> 8))
    bytes.append(UInt8(truncatingIfNeeded: count))
  }

  private static func readByte(from bytes: Span<UInt8>, at offset: inout Int) throws -> UInt8 {
    guard offset < bytes.count else { throw UnixDatagramWireError.truncated }
    defer { offset += 1 }
    return bytes[offset]
  }

  private static func readFlag(from bytes: Span<UInt8>, at offset: inout Int) throws -> Bool {
    switch try readByte(from: bytes, at: &offset) {
    case 0: false
    case 1: true
    default: throw UnixDatagramWireError.invalidFlags
    }
  }

  private static func readCount(from bytes: Span<UInt8>, at offset: inout Int) throws -> Int {
    guard offset <= bytes.count - 2 else { throw UnixDatagramWireError.truncated }
    defer { offset += 2 }
    return Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
  }

  private static func readString(
    from bytes: Span<UInt8>,
    at offset: inout Int,
    in strings: [String]
  ) throws -> String {
    let index = try readCount(from: bytes, at: &offset)
    guard index < strings.count else { throw UnixDatagramWireError.stringIndexOutOfRange }
    return strings[index]
  }
}

/// A message measured for a batch.
///
/// An entry's length does not depend on where its strings land in a batch's table, so a batch
/// needs to know only this to keep its own length exact: the entry's bytes, and the strings it
/// adds to the table if no other entry has already.
struct UnixDatagramWireEntry: Sendable {
  let message: OrbitIPCMessage

  /// Every string the entry refers to, each once, in the order the entry first refers to it.
  let strings: [String]

  /// The entry's length, from its kind to the end of its payload.
  let byteCount: Int

  /// Measures `message` as it is.
  ///
  /// - Throws: ``UnixDatagramWireError/databaseIdentifierTooLong`` or
  ///   ``UnixDatagramWireError/regionTooLarge`` if part of it cannot be encoded.
  init(_ message: OrbitIPCMessage) throws {
    switch message {
    case .transactionDidCommit(let commit):
      let database = commit.databaseIdentifier.rawValue
      guard database.utf8.count <= UInt16.max else {
        throw UnixDatagramWireError.databaseIdentifierTooLong
      }
      let payloadByteCount = 2 + (try UnixDatagramWireProtocol.byteCount(of: commit.region))
      guard payloadByteCount <= UInt16.max else { throw UnixDatagramWireError.regionTooLarge }
      self.message = message
      self.strings = UnixDatagramWireProtocol.strings(in: commit.region, after: [database])
      self.byteCount = 3 + payloadByteCount
    }
  }

  /// Measures `message`, broadening its region to the full database if a batch holding nothing
  /// else would be longer than `maximumByteCount`.
  ///
  /// - Throws: ``UnixDatagramWireError/datagramTooLarge`` if even the broadened message does not
  ///   fit, or ``UnixDatagramWireError/databaseIdentifierTooLong``.
  init(_ message: OrbitIPCMessage, fittingIn maximumByteCount: Int) throws {
    let fits = { UnixDatagramWireBatch().byteCount(appending: $0) <= maximumByteCount }
    if let entry = try? Self(message), fits(entry) {
      self = entry
      return
    }
    // An identifier too long to encode fails here again, broadened or not.
    let entry = try Self(
      .transactionDidCommit(
        .init(databaseIdentifier: message.databaseIdentifier, region: .fullDatabase)
      )
    )
    guard fits(entry) else { throw UnixDatagramWireError.datagramTooLarge }
    self = entry
  }

  fileprivate func append(to bytes: inout [UInt8], indices: [String: Int]) {
    switch self.message {
    case .transactionDidCommit(let commit):
      bytes.append(1)
      UnixDatagramWireProtocol.appendCount(self.byteCount - 3, to: &bytes)
      UnixDatagramWireProtocol.appendCount(indices[commit.databaseIdentifier.rawValue]!, to: &bytes)
      UnixDatagramWireProtocol.appendRegion(commit.region, to: &bytes, indices: indices)
    }
  }
}

/// Entries bound for one datagram, and the exact length of its encoding.
struct UnixDatagramWireBatch {
  private(set) var entries: [UnixDatagramWireEntry] = []

  /// The exact length of ``encoded()``, which starts as a header and an empty string table.
  private(set) var byteCount = 10

  private var strings: [String] = []
  private var indices: [String: Int] = [:]

  /// The length this batch would have with `entry` appended.
  func byteCount(appending entry: UnixDatagramWireEntry) -> Int {
    entry.strings.reduce(self.byteCount + entry.byteCount) { byteCount, string in
      self.indices[string] == nil ? byteCount + 2 + string.utf8.count : byteCount
    }
  }

  mutating func append(_ entry: UnixDatagramWireEntry) {
    self.byteCount = self.byteCount(appending: entry)
    for string in entry.strings where self.indices[string] == nil {
      self.indices[string] = self.strings.count
      self.strings.append(string)
    }
    self.entries.append(entry)
  }

  /// Encodes the batch, which must not be empty, as one datagram.
  func encoded() -> [UInt8] {
    precondition(!self.entries.isEmpty, "An empty batch has no encoding")
    var bytes: [UInt8] = [0x4F, 0x52, 0x42, 0x54, 1, 0]  // ORBT, version 1, no flags
    UnixDatagramWireProtocol.appendCount(self.entries.count, to: &bytes)
    UnixDatagramWireProtocol.appendStringTable(self.strings, to: &bytes)
    for entry in self.entries {
      entry.append(to: &bytes, indices: self.indices)
    }
    assert(bytes.count == self.byteCount)
    return bytes
  }
}
