enum OrbitIPCWireError: Error, Equatable {
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
enum OrbitIPCWireProtocol {
  /// The bytes of a batch holding nothing but its header and an empty string table.
  static let emptyBatchByteCount = 10

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
    var batch = OrbitIPCWireBatch<Void>()
    batch.append(try OrbitIPCWireEntry(message, fittingIn: maximumByteCount), tag: ())
    return batch.encoded()
  }

  /// Decodes every entry of a datagram this decoder knows the kind of.
  ///
  /// - Parameter bytes: The datagram.
  /// - Returns: The entries' messages, in the order they were encoded.
  /// - Throws: An ``OrbitIPCWireError`` if any part of the datagram is malformed, in which case
  ///   none of it is delivered.
  static func decode(_ bytes: Span<UInt8>) throws -> [OrbitIPCMessage] {
    guard bytes.count >= 8 else { throw OrbitIPCWireError.truncated }
    guard bytes[0] == 0x4F, bytes[1] == 0x52, bytes[2] == 0x42, bytes[3] == 0x54 else {
      throw OrbitIPCWireError.invalidMagic
    }
    guard bytes[4] == 1 else {
      throw OrbitIPCWireError.unsupportedProtocolVersion(bytes[4])
    }
    guard bytes[5] == 0 else { throw OrbitIPCWireError.invalidFlags }
    var offset = 6
    let entryCount = try readCount(from: bytes, at: &offset)
    guard entryCount > 0 else { throw OrbitIPCWireError.emptyBatch }
    let strings = try readStringTable(from: bytes, at: &offset)

    var messages: [OrbitIPCMessage] = []
    messages.reserveCapacity(entryCount)
    for _ in 0..<entryCount {
      guard offset < bytes.count else { throw OrbitIPCWireError.truncated }
      let kind = bytes[offset]
      offset += 1
      let payloadCount = try readCount(from: bytes, at: &offset)
      guard payloadCount <= bytes.count - offset else { throw OrbitIPCWireError.truncated }
      let payload = bytes.extracting(offset..<(offset + payloadCount))
      offset += payloadCount
      guard kind == 1 else { continue }

      var payloadOffset = 0
      let database = try readString(from: payload, at: &payloadOffset, in: strings)
      let region = try readRegion(from: payload, at: &payloadOffset, strings: strings)
      guard payloadOffset == payload.count else {
        throw OrbitIPCWireError.payloadLengthMismatch
      }
      messages.append(
        .transactionDidCommit(
          .init(databaseIdentifier: OrbitDatabaseIdentifier(rawValue: database), region: region)
        )
      )
    }
    guard offset == bytes.count else { throw OrbitIPCWireError.trailingBytes }
    return messages
  }

  // MARK: - String Tables

  /// Appends a string table holding `strings`, whose indices are their positions in it.
  static func appendStringTable(_ strings: [String], to bytes: inout [UInt8]) {
    appendCount(strings.count, to: &bytes)
    for string in strings {
      appendCount(string.utf8.count, to: &bytes)
      bytes.append(contentsOf: string.utf8)
    }
  }

  /// Reads a string table, validating each string's UTF-8 once.
  static func readStringTable(
    from bytes: Span<UInt8>,
    at offset: inout Int
  ) throws -> [String] {
    let count = try readCount(from: bytes, at: &offset)
    var strings: [String] = []
    strings.reserveCapacity(count)
    for _ in 0..<count {
      let length = try readCount(from: bytes, at: &offset)
      guard length <= bytes.count - offset else { throw OrbitIPCWireError.truncated }
      let string = bytes.extracting(offset..<(offset + length))
        .withUnsafeBufferPointer { buffer -> String? in
          // `String(decoding:as:)` repairs malformed sequences rather than rejecting them, so the
          // round trip is what rejects them. `String(validating:as:)` says this in one call, but
          // only on platforms newer than the ones this package supports.
          let decoded = String(decoding: buffer, as: UTF8.self)
          return decoded.utf8.elementsEqual(buffer) ? decoded : nil
        }
      guard let string else { throw OrbitIPCWireError.invalidUTF8 }
      strings.append(string)
      offset += length
    }
    return strings
  }

  // MARK: - Regions

  /// The strings `region` refers to, in the order its encoding first refers to them.
  static func strings(in region: OrbitDatabaseRegion) -> [String] {
    var strings: [String] = []
    for (table, tableRegion) in sortedTables(of: region) {
      strings.append(table.schema.rawValue)
      strings.append(table.name)
      strings.append(contentsOf: tableRegion.exceptions.sorted())
    }
    return strings
  }

  /// The length of `region`'s encoding, which does not depend on the strings it refers to.
  ///
  /// - Throws: ``OrbitIPCWireError/regionTooLarge`` if a count or string does not fit in 16 bits.
  static func byteCount(of region: OrbitDatabaseRegion) throws -> Int {
    guard region.tableRegions.count <= UInt16.max else { throw OrbitIPCWireError.regionTooLarge }
    var byteCount = 3
    for (table, tableRegion) in region.tableRegions {
      guard tableRegion.exceptions.count <= UInt16.max,
        table.schema.rawValue.utf8.count <= UInt16.max,
        table.name.utf8.count <= UInt16.max,
        tableRegion.exceptions.allSatisfy({ $0.utf8.count <= UInt16.max })
      else { throw OrbitIPCWireError.regionTooLarge }
      byteCount += 7 + 2 * tableRegion.exceptions.count
    }
    return byteCount
  }

  /// Appends `region`, naming each string by its index in `indices`.
  static func appendRegion(
    _ region: OrbitDatabaseRegion,
    to bytes: inout [UInt8],
    indices: [String: UInt16]
  ) {
    bytes.append(region.includesUnspecifiedTables ? 1 : 0)
    let tables = sortedTables(of: region)
    appendCount(tables.count, to: &bytes)
    for (table, tableRegion) in tables {
      appendIndex(of: table.schema.rawValue, in: indices, to: &bytes)
      appendIndex(of: table.name, in: indices, to: &bytes)
      bytes.append(tableRegion.includesUnspecifiedColumns ? 1 : 0)
      appendCount(tableRegion.exceptions.count, to: &bytes)
      for column in tableRegion.exceptions.sorted() {
        appendIndex(of: column, in: indices, to: &bytes)
      }
    }
  }

  /// Reads a region whose strings are indices into `strings`.
  static func readRegion(
    from bytes: Span<UInt8>,
    at offset: inout Int,
    strings: [String]
  ) throws -> OrbitDatabaseRegion {
    let includesUnspecifiedTables = try readFlag(from: bytes, at: &offset)
    let tableCount = try readCount(from: bytes, at: &offset)
    var tables: [OrbitDatabaseRegion.TableIdentifier: OrbitDatabaseRegion.TableRegion] = [:]
    tables.reserveCapacity(tableCount)

    for _ in 0..<tableCount {
      let schema = try readString(from: bytes, at: &offset, in: strings)
      let name = try readString(from: bytes, at: &offset, in: strings)
      let table = OrbitDatabaseRegion.TableIdentifier(
        schema: SQLiteSchemaName(schema),
        name: name
      )
      guard tables[table] == nil else {
        throw OrbitIPCWireError.duplicateRegionEntry
      }
      let includesUnspecifiedColumns = try readFlag(from: bytes, at: &offset)
      let columnCount = try readCount(from: bytes, at: &offset)
      var columns: Set<String> = []
      columns.reserveCapacity(columnCount)
      for _ in 0..<columnCount {
        let column = try readString(from: bytes, at: &offset, in: strings).asciiLowercased
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

  // MARK: - Primitives

  static func appendCount(_ count: Int, to bytes: inout [UInt8]) {
    let count = UInt16(count)
    bytes.append(UInt8(truncatingIfNeeded: count >> 8))
    bytes.append(UInt8(truncatingIfNeeded: count))
  }

  static func appendIndex(
    of string: String,
    in indices: [String: UInt16],
    to bytes: inout [UInt8]
  ) {
    appendCount(Int(indices[string]!), to: &bytes)
  }

  private static func sortedTables(
    of region: OrbitDatabaseRegion
  ) -> [(key: OrbitDatabaseRegion.TableIdentifier, value: OrbitDatabaseRegion.TableRegion)] {
    region.tableRegions.sorted {
      ($0.key.schema.rawValue, $0.key.name) < ($1.key.schema.rawValue, $1.key.name)
    }
  }

  private static func readFlag(from bytes: Span<UInt8>, at offset: inout Int) throws -> Bool {
    guard offset < bytes.count else { throw OrbitIPCWireError.truncated }
    defer { offset += 1 }
    switch bytes[offset] {
    case 0: return false
    case 1: return true
    default: throw OrbitIPCWireError.invalidFlags
    }
  }

  private static func readCount(from bytes: Span<UInt8>, at offset: inout Int) throws -> Int {
    guard offset <= bytes.count - 2 else { throw OrbitIPCWireError.truncated }
    defer { offset += 2 }
    return Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
  }

  private static func readString(
    from bytes: Span<UInt8>,
    at offset: inout Int,
    in strings: [String]
  ) throws -> String {
    let index = try readCount(from: bytes, at: &offset)
    guard index < strings.count else { throw OrbitIPCWireError.stringIndexOutOfRange }
    return strings[index]
  }
}

/// A message measured for a batch.
///
/// An entry's length does not depend on where its strings land in a batch's table, so what a
/// batch needs to know of an entry to keep its own length exact is only this: the entry's bytes,
/// and the strings it adds to the table if no other entry has already.
struct OrbitIPCWireEntry: Hashable, Sendable {
  /// The message the entry carries.
  let message: OrbitIPCMessage

  /// Every string the entry refers to, each once, in the order the entry first refers to it.
  let strings: [String]

  /// The entry's length, from its kind to the end of its payload.
  let byteCount: Int

  /// Measures `message` as it is.
  ///
  /// - Throws: ``OrbitIPCWireError/databaseIdentifierTooLong`` or
  ///   ``OrbitIPCWireError/regionTooLarge`` if part of it cannot be encoded.
  init(_ message: OrbitIPCMessage) throws {
    switch message {
    case .transactionDidCommit(let commit):
      let database = commit.databaseIdentifier.rawValue
      guard database.utf8.count <= UInt16.max else {
        throw OrbitIPCWireError.databaseIdentifierTooLong
      }
      let payloadByteCount = 2 + (try OrbitIPCWireProtocol.byteCount(of: commit.region))
      guard payloadByteCount <= UInt16.max else { throw OrbitIPCWireError.regionTooLarge }
      var seen: Set<String> = [database]
      var strings = [database]
      for string in OrbitIPCWireProtocol.strings(in: commit.region)
      where seen.insert(string).inserted {
        strings.append(string)
      }
      self.message = message
      self.strings = strings
      self.byteCount = 3 + payloadByteCount
    }
  }

  /// Measures `message`, broadening its region to the full database if a batch holding nothing
  /// else would be longer than `maximumByteCount`.
  ///
  /// - Throws: ``OrbitIPCWireError/datagramTooLarge`` if even the broadened message does not fit.
  init(_ message: OrbitIPCMessage, fittingIn maximumByteCount: Int) throws {
    do {
      let entry = try Self(message)
      if OrbitIPCWireBatch<Void>.byteCount(of: entry) <= maximumByteCount {
        self = entry
        return
      }
    } catch OrbitIPCWireError.regionTooLarge {
    }
    let entry = try Self(message.withFullDatabaseRegion)
    guard OrbitIPCWireBatch<Void>.byteCount(of: entry) <= maximumByteCount else {
      throw OrbitIPCWireError.datagramTooLarge
    }
    self = entry
  }

  fileprivate func append(to bytes: inout [UInt8], indices: [String: UInt16]) {
    switch self.message {
    case .transactionDidCommit(let commit):
      bytes.append(1)
      OrbitIPCWireProtocol.appendCount(self.byteCount - 3, to: &bytes)
      OrbitIPCWireProtocol.appendIndex(
        of: commit.databaseIdentifier.rawValue,
        in: indices,
        to: &bytes
      )
      OrbitIPCWireProtocol.appendRegion(commit.region, to: &bytes, indices: indices)
    }
  }
}

/// Entries bound for one datagram, whose exact encoded length is kept as they come and go.
///
/// Each string's table slot is reference counted by the entries that refer to it, so removing an
/// entry gives back the slots only it used. Indices are assigned only by ``encoded()``.
struct OrbitIPCWireBatch<Tag> {
  struct Element {
    let entry: OrbitIPCWireEntry
    let tag: Tag
  }

  /// The entries, in the order they were appended.
  private(set) var elements: [Element] = []

  /// The exact length of ``encoded()``.
  private(set) var byteCount = OrbitIPCWireProtocol.emptyBatchByteCount

  private var stringReferenceCounts: [String: Int] = [:]

  var isEmpty: Bool { self.elements.isEmpty }

  /// The length of a batch holding `entry` and nothing else.
  static func byteCount(of entry: OrbitIPCWireEntry) -> Int {
    Self().byteCount(appending: entry)
  }

  /// The length this batch would have with `entry` appended.
  func byteCount(appending entry: OrbitIPCWireEntry) -> Int {
    entry.strings.reduce(self.byteCount + entry.byteCount) { byteCount, string in
      self.stringReferenceCounts[string] == nil ? byteCount + 2 + string.utf8.count : byteCount
    }
  }

  mutating func append(_ entry: OrbitIPCWireEntry, tag: Tag) {
    self.byteCount = self.byteCount(appending: entry)
    for string in entry.strings {
      self.stringReferenceCounts[string, default: 0] += 1
    }
    self.elements.append(Element(entry: entry, tag: tag))
  }

  @discardableResult
  mutating func remove(at index: Int) -> Element {
    let element = self.elements.remove(at: index)
    self.byteCount -= element.entry.byteCount
    for string in element.entry.strings {
      self.stringReferenceCounts[string]! -= 1
      if self.stringReferenceCounts[string] == 0 {
        self.stringReferenceCounts[string] = nil
        self.byteCount -= 2 + string.utf8.count
      }
    }
    return element
  }

  mutating func removeAll() -> [Element] {
    defer { self = Self() }
    return self.elements
  }

  /// Encodes the batch, which must not be empty, as one datagram.
  func encoded() -> [UInt8] {
    precondition(!self.elements.isEmpty, "An empty batch has no encoding")
    var indices: [String: UInt16] = [:]
    var strings: [String] = []
    for element in self.elements {
      for string in element.entry.strings where indices[string] == nil {
        indices[string] = UInt16(strings.count)
        strings.append(string)
      }
    }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(self.byteCount)
    bytes.append(contentsOf: [0x4F, 0x52, 0x42, 0x54, 1, 0])  // ORBT, version 1, no flags
    OrbitIPCWireProtocol.appendCount(self.elements.count, to: &bytes)
    OrbitIPCWireProtocol.appendStringTable(strings, to: &bytes)
    for element in self.elements {
      element.entry.append(to: &bytes, indices: indices)
    }
    assert(bytes.count == self.byteCount)
    return bytes
  }
}

extension OrbitIPCWireBatch: Sendable where Tag: Sendable {}
extension OrbitIPCWireBatch.Element: Sendable where Tag: Sendable {}

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
