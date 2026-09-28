import Testing

@testable import SQLiteOrbit

@Test
func unixDatagramWireProtocolHasStableVersionOneEncoding() throws {
  let message = databaseIPCMessage("db")
  let encoded = try UnixDatagramWireProtocol.encode(message)
  #expect(
    encoded == [
      0x4F, 0x52, 0x42, 0x54, 1, 0, 0, 1,  // header: ORBT, version 1, no flags, one entry
      0, 1, 0, 2, 0x64, 0x62,  // string table: "db"
      1, 0, 5, 0, 0, 1, 0, 0  // commit of string 0, full database
    ]
  )
  #expect(try decodeDatabaseIPCMessages(encoded) == [message])
}

@Test
func unixDatagramWireProtocolRoundTripsEveryRegionShape() throws {
  for region in databaseIPCRegions {
    let message = databaseIPCMessage(region: region)
    #expect(try decodeDatabaseIPCMessages(UnixDatagramWireProtocol.encode(message)) == [message])
  }
}

@Test
func unixDatagramWireBatchKeepsItsExactLengthAndRoundTripsInOrder() throws {
  let messages = databaseIPCRegions.enumerated()
    .map { index, region in
      databaseIPCMessage(index.isMultiple(of: 3) ? "first" : "second", region: region)
    }
  var batch = UnixDatagramWireBatch()

  for message in messages {
    let entry = try UnixDatagramWireEntry(message)
    #expect(
      UnixDatagramWireBatch().byteCount(appending: entry)
        == (try UnixDatagramWireProtocol.encode(message).count)
    )
    let expected = batch.byteCount(appending: entry)
    batch.append(entry)
    #expect(batch.byteCount == expected)
    #expect(batch.encoded().count == expected)
  }

  #expect(try decodeDatabaseIPCMessages(batch.encoded()) == messages)
}

@Test
func unixDatagramWireProtocolSharesStringsAcrossABatch() throws {
  let title = OrbitDatabaseRegion(column: "title", in: "items")
  let notes = OrbitDatabaseRegion(column: "notes", in: "items")
  var batch = UnixDatagramWireBatch()
  for region in [title, notes, title.union(notes), .fullDatabase] {
    batch.append(try UnixDatagramWireEntry(databaseIPCMessage(region: region)))
  }
  let encoded = batch.encoded()

  // "db", "main", "items", "title" and "notes", each once however many entries name it.
  #expect(encoded[8...9] == [0, 5])
  #expect(
    try decodeDatabaseIPCMessages(encoded)
      == [title, notes, title.union(notes), .fullDatabase].map { databaseIPCMessage(region: $0) }
  )
}

@Test
func unixDatagramWireProtocolEncodingIsCanonical() throws {
  let first = OrbitDatabaseRegion(column: "first", in: "items")
  let second = OrbitDatabaseRegion(column: "second", in: "items")

  #expect(
    try UnixDatagramWireProtocol.encode(databaseIPCMessage(region: first.union(second)))
      == UnixDatagramWireProtocol.encode(databaseIPCMessage(region: second.union(first)))
  )
}

@Test
func unixDatagramWireProtocolRejectsEveryTruncatedPrefix() throws {
  var batch = UnixDatagramWireBatch()
  for region in [OrbitDatabaseRegion(column: "title", in: "items"), .fullDatabase] {
    batch.append(try UnixDatagramWireEntry(databaseIPCMessage("example-database", region: region)))
  }

  let encoded = batch.encoded()
  for count in encoded.indices {
    #expect(throws: UnixDatagramWireError.self) {
      try decodeDatabaseIPCMessages(Array(encoded.prefix(count)))
    }
  }
}

@Test
func unixDatagramWireProtocolSkipsEntriesOfUnknownKinds() throws {
  let datagram = rawDatagram(
    entries: [
      (1, commitPayload()),
      (9, [0xff, 0xff, 0xff]),
      (1, commitPayload(regionFlags: 0))
    ]
  )

  #expect(
    try decodeDatabaseIPCMessages(datagram) == [
      databaseIPCMessage(region: .fullDatabase), databaseIPCMessage(region: .empty)
    ]
  )
}

@Test
func unixDatagramWireProtocolRejectsMalformedHeaders() {
  var badMagic = rawDatagram()
  badMagic[0] = 0
  #expect(throws: UnixDatagramWireError.invalidMagic) { try decodeDatabaseIPCMessages(badMagic) }
  #expect(throws: UnixDatagramWireError.unsupportedProtocolVersion(2)) {
    try decodeDatabaseIPCMessages(rawDatagram(version: 2))
  }
  #expect(throws: UnixDatagramWireError.invalidFlags) {
    try decodeDatabaseIPCMessages(rawDatagram(flags: 1))
  }
  #expect(throws: UnixDatagramWireError.emptyBatch) {
    try decodeDatabaseIPCMessages(rawDatagram(entries: []))
  }
  #expect(throws: UnixDatagramWireError.trailingBytes) {
    try decodeDatabaseIPCMessages(rawDatagram() + [0])
  }
}

@Test
func unixDatagramWireProtocolRejectsMalformedStrings() {
  #expect(throws: UnixDatagramWireError.invalidUTF8) {
    try decodeDatabaseIPCMessages(rawDatagram(strings: [[0xff]]))
  }
  #expect(throws: UnixDatagramWireError.stringIndexOutOfRange) {
    try decodeDatabaseIPCMessages(rawDatagram(entries: [(1, commitPayload(database: 1))]))
  }
  #expect(throws: UnixDatagramWireError.stringIndexOutOfRange) {
    try decodeDatabaseIPCMessages(
      rawDatagram(
        strings: utf8("db", "main"),
        entries: [(1, commitPayload(regionFlags: 0, tables: [(1, 2, 1, [])]))]
      )
    )
  }
}

@Test
func unixDatagramWireProtocolRejectsMalformedPayloads() {
  #expect(throws: UnixDatagramWireError.payloadLengthMismatch) {
    try decodeDatabaseIPCMessages(rawDatagram(entries: [(1, commitPayload() + [0])]))
  }
  #expect(throws: UnixDatagramWireError.truncated) {
    try decodeDatabaseIPCMessages(rawDatagram(entries: [(1, Array(commitPayload().dropLast()))]))
  }
  #expect(throws: UnixDatagramWireError.invalidFlags) {
    try decodeDatabaseIPCMessages(rawDatagram(entries: [(1, commitPayload(regionFlags: 2))]))
  }
  #expect(throws: UnixDatagramWireError.invalidFlags) {
    try decodeDatabaseIPCMessages(
      rawDatagram(
        strings: utf8("db", "main", "items"),
        entries: [(1, commitPayload(regionFlags: 0, tables: [(1, 2, 2, [])]))]
      )
    )
  }
}

@Test
func unixDatagramWireProtocolRejectsDuplicateRegionEntries() {
  // Table names and columns compare without regard to ASCII case, so differently spelled strings
  // can still name the same one.
  let strings = utf8("db", "main", "items", "Items", "title", "TITLE")
  #expect(throws: UnixDatagramWireError.duplicateRegionEntry) {
    try decodeDatabaseIPCMessages(
      rawDatagram(
        strings: strings,
        entries: [(1, commitPayload(regionFlags: 0, tables: [(1, 2, 1, []), (1, 3, 1, [])]))]
      )
    )
  }
  #expect(throws: UnixDatagramWireError.duplicateRegionEntry) {
    try decodeDatabaseIPCMessages(
      rawDatagram(
        strings: strings,
        entries: [(1, commitPayload(regionFlags: 0, tables: [(1, 2, 0, [4, 5])]))]
      )
    )
  }
}

@Test
func unixDatagramWireProtocolBroadensOversizedRegions() throws {
  let message = databaseIPCMessage(
    region: OrbitDatabaseRegion(column: "title", in: "items")
  )
  let exact = try UnixDatagramWireProtocol.encode(message)
  let encoded = try UnixDatagramWireProtocol.encode(message, maximumByteCount: exact.count - 1)

  #expect(try decodeDatabaseIPCMessages(exact) == [message])
  #expect(try decodeDatabaseIPCMessages(encoded) == [databaseIPCMessage(region: .fullDatabase)])
  #expect(throws: UnixDatagramWireError.datagramTooLarge) {
    try UnixDatagramWireProtocol.encode(message, maximumByteCount: 21)
  }
}

@Test
func unixDatagramWireProtocolRejectsOversizedDatabaseIdentifiers() {
  #expect(throws: UnixDatagramWireError.databaseIdentifierTooLong) {
    try UnixDatagramWireProtocol.encode(databaseIPCMessage(String(repeating: "x", count: 65_536)))
  }
}

@Test
func unixDatagramMarkersRoundTripEveryRegionShape() throws {
  for region in databaseIPCRegions {
    let encoded = UnixDatagramWireProtocol.encodeMarker(region)
    #expect(try decodeDatabaseIPCMarker(encoded) == region)
  }
  // "main", "items" and "title" once each, then the region naming them by index.
  #expect(
    UnixDatagramWireProtocol.encodeMarker(OrbitDatabaseRegion(column: "title", in: "items")) == [
      0, 3, 0, 4, 0x6D, 0x61, 0x69, 0x6E, 0, 5, 0x69, 0x74, 0x65, 0x6D, 0x73,
      0, 5, 0x74, 0x69, 0x74, 0x6C, 0x65,
      0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 2
    ]
  )
}

@Test
func unixDatagramMarkersRejectMalformedContents() throws {
  let encoded = UnixDatagramWireProtocol.encodeMarker(
    OrbitDatabaseRegion(column: "title", in: "items")
  )
  for count in encoded.indices {
    #expect(throws: UnixDatagramWireError.self) {
      try decodeDatabaseIPCMarker(Array(encoded.prefix(count)))
    }
  }
  #expect(throws: UnixDatagramWireError.trailingBytes) {
    try decodeDatabaseIPCMarker(encoded + [0])
  }
}

private func decodeDatabaseIPCMarker(_ bytes: [UInt8]) throws -> OrbitDatabaseRegion {
  try bytes.withUnsafeBufferPointer {
    try UnixDatagramWireProtocol.decodeMarker(Span(_unsafeElements: $0))
  }
}

private let databaseIPCRegions: [OrbitDatabaseRegion] = {
  let table = OrbitDatabaseRegion(table: "items")
  let column = OrbitDatabaseRegion(column: "title", in: "items")
  let attached = OrbitDatabaseRegion(
    columns: ["first", "second"],
    in: "records",
    schema: "archive"
  )
  return [
    .empty,
    .fullDatabase,
    table,
    column,
    column.union(attached),
    table.subtracting(column),
    OrbitDatabaseRegion.fullDatabase.subtracting(column),
    OrbitDatabaseRegion.fullDatabase.subtracting(table)
  ]
}()

private func databaseIPCMessage(
  _ identifier: String = "db",
  region: OrbitDatabaseRegion = .fullDatabase
) -> OrbitIPCMessage {
  .transactionDidCommit(
    .init(databaseIdentifier: .init(rawValue: identifier), region: region)
  )
}

private func decodeDatabaseIPCMessages(_ bytes: [UInt8]) throws -> [OrbitIPCMessage] {
  try bytes.withUnsafeBufferPointer {
    try UnixDatagramWireProtocol.decode(Span(_unsafeElements: $0))
  }
}

/// Lays out a datagram field by field, so a test can get any one of them wrong, by default one
/// committing the full database `db`.
private func rawDatagram(
  version: UInt8 = 1,
  flags: UInt8 = 0,
  strings: [[UInt8]] = utf8("db"),
  entries: [(kind: UInt8, payload: [UInt8])] = [(1, commitPayload())]
) -> [UInt8] {
  var bytes: [UInt8] = [0x4F, 0x52, 0x42, 0x54, version, flags] + bigEndian(entries.count)
  bytes += bigEndian(strings.count)
  for string in strings {
    bytes += bigEndian(string.count) + string
  }
  for entry in entries {
    bytes += [entry.kind] + bigEndian(entry.payload.count) + entry.payload
  }
  return bytes
}

/// A commit's payload, whose region covers the full database unless told otherwise.
private func commitPayload(
  database: Int = 0,
  regionFlags: UInt8 = 1,
  tables: [(schema: Int, name: Int, flags: UInt8, columns: [Int])] = []
) -> [UInt8] {
  var bytes = bigEndian(database) + [regionFlags] + bigEndian(tables.count)
  for table in tables {
    bytes += bigEndian(table.schema) + bigEndian(table.name) + [table.flags]
    bytes += bigEndian(table.columns.count)
    for column in table.columns {
      bytes += bigEndian(column)
    }
  }
  return bytes
}

private func bigEndian(_ value: Int) -> [UInt8] {
  [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

private func utf8(_ strings: String...) -> [[UInt8]] {
  strings.map { Array($0.utf8) }
}
