import Testing

@testable import SQLiteOrbit

@Test
func databaseIPCWireProtocolHasStableVersionOneEncoding() throws {
  let message = databaseIPCMessage("db")
  let encoded = try OrbitIPCWireProtocol.encode(message)
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
func databaseIPCWireProtocolRoundTripsEveryRegionShape() throws {
  for region in databaseIPCRegions {
    let message = databaseIPCMessage(region: region)
    #expect(try decodeDatabaseIPCMessages(OrbitIPCWireProtocol.encode(message)) == [message])
  }
}

@Test
func databaseIPCWireProtocolRoundTripsBatchesInOrder() throws {
  let messages = databaseIPCRegions.enumerated()
    .map { index, region in
      databaseIPCMessage(index.isMultiple(of: 3) ? "first" : "second", region: region)
    }
  var batch = OrbitIPCWireBatch<Int>()
  for (index, message) in messages.enumerated() {
    batch.append(try OrbitIPCWireEntry(message), tag: index)
  }

  #expect(try decodeDatabaseIPCMessages(batch.encoded()) == messages)
}

@Test
func databaseIPCWireProtocolSharesStringsAcrossABatch() throws {
  let title = OrbitDatabaseRegion(column: "title", in: "items")
  let notes = OrbitDatabaseRegion(column: "notes", in: "items")
  var batch = OrbitIPCWireBatch<Void>()
  for region in [title, notes, title.union(notes), .fullDatabase] {
    batch.append(try OrbitIPCWireEntry(databaseIPCMessage(region: region)), tag: ())
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
func databaseIPCWireBatchKeepsItsExactLengthAsEntriesComeAndGo() throws {
  let entries = try databaseIPCRegions.enumerated()
    .map { index, region in
      try OrbitIPCWireEntry(databaseIPCMessage(index.isMultiple(of: 2) ? "a" : "b", region: region))
    }
  var batch = OrbitIPCWireBatch<Int>()
  #expect(batch.byteCount == OrbitIPCWireProtocol.emptyBatchByteCount)

  for (index, entry) in entries.enumerated() {
    let expected = batch.byteCount(appending: entry)
    batch.append(entry, tag: index)
    #expect(batch.byteCount == expected)
    #expect(batch.encoded().count == batch.byteCount)
  }
  for index in [3, 0, 4, 1] {
    batch.remove(at: min(index, batch.elements.count - 1))
    #expect(batch.encoded().count == batch.byteCount)
  }
  _ = batch.removeAll()
  #expect(batch.byteCount == OrbitIPCWireProtocol.emptyBatchByteCount)

  for entry in entries {
    #expect(
      OrbitIPCWireBatch<Void>.byteCount(of: entry)
        == (try OrbitIPCWireProtocol.encode(entry.message).count)
    )
  }
}

@Test
func databaseIPCWireProtocolEncodingIsCanonical() throws {
  let first = OrbitDatabaseRegion(column: "first", in: "items")
  let second = OrbitDatabaseRegion(column: "second", in: "items")

  #expect(
    try OrbitIPCWireProtocol.encode(databaseIPCMessage(region: first.union(second)))
      == OrbitIPCWireProtocol.encode(databaseIPCMessage(region: second.union(first)))
  )
}

@Test
func databaseIPCWireProtocolRejectsEveryTruncatedPrefix() throws {
  var batch = OrbitIPCWireBatch<Void>()
  for region in [OrbitDatabaseRegion(column: "title", in: "items"), .fullDatabase] {
    batch.append(
      try OrbitIPCWireEntry(databaseIPCMessage("example-database", region: region)),
      tag: ()
    )
  }
  let encoded = batch.encoded()
  for count in encoded.indices {
    #expect(throws: OrbitIPCWireError.self) {
      try decodeDatabaseIPCMessages(Array(encoded.prefix(count)))
    }
  }
}

@Test
func databaseIPCWireProtocolSkipsEntriesOfUnknownKinds() throws {
  let datagram = rawDatagram(
    strings: utf8("db"),
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
func databaseIPCWireProtocolRejectsMalformedHeaders() {
  var badMagic = rawDatagram(strings: utf8("db"), entries: [(1, commitPayload())])
  badMagic[0] = 0
  #expect(throws: OrbitIPCWireError.invalidMagic) { try decodeDatabaseIPCMessages(badMagic) }
  #expect(throws: OrbitIPCWireError.unsupportedProtocolVersion(2)) {
    try decodeDatabaseIPCMessages(
      rawDatagram(version: 2, strings: utf8("db"), entries: [(1, commitPayload())])
    )
  }
  #expect(throws: OrbitIPCWireError.invalidFlags) {
    try decodeDatabaseIPCMessages(
      rawDatagram(flags: 1, strings: utf8("db"), entries: [(1, commitPayload())])
    )
  }
  #expect(throws: OrbitIPCWireError.emptyBatch) {
    try decodeDatabaseIPCMessages(rawDatagram(strings: utf8("db"), entries: []))
  }
  #expect(throws: OrbitIPCWireError.trailingBytes) {
    try decodeDatabaseIPCMessages(
      rawDatagram(strings: utf8("db"), entries: [(1, commitPayload())]) + [0]
    )
  }
}

@Test
func databaseIPCWireProtocolRejectsMalformedStrings() {
  #expect(throws: OrbitIPCWireError.invalidUTF8) {
    try decodeDatabaseIPCMessages(
      rawDatagram(strings: [[0xff]], entries: [(1, commitPayload())])
    )
  }
  #expect(throws: OrbitIPCWireError.stringIndexOutOfRange) {
    try decodeDatabaseIPCMessages(
      rawDatagram(strings: utf8("db"), entries: [(1, commitPayload(database: 1))])
    )
  }
  #expect(throws: OrbitIPCWireError.stringIndexOutOfRange) {
    try decodeDatabaseIPCMessages(
      rawDatagram(
        strings: utf8("db", "main"),
        entries: [(1, commitPayload(regionFlags: 0, tables: [(1, 2, 1, [])]))]
      )
    )
  }
}

@Test
func databaseIPCWireProtocolRejectsMalformedPayloads() {
  #expect(throws: OrbitIPCWireError.payloadLengthMismatch) {
    try decodeDatabaseIPCMessages(
      rawDatagram(strings: utf8("db"), entries: [(1, commitPayload() + [0])])
    )
  }
  #expect(throws: OrbitIPCWireError.truncated) {
    try decodeDatabaseIPCMessages(
      rawDatagram(strings: utf8("db"), entries: [(1, Array(commitPayload().dropLast()))])
    )
  }
  #expect(throws: OrbitIPCWireError.invalidFlags) {
    try decodeDatabaseIPCMessages(
      rawDatagram(strings: utf8("db"), entries: [(1, commitPayload(regionFlags: 2))])
    )
  }
  #expect(throws: OrbitIPCWireError.invalidFlags) {
    try decodeDatabaseIPCMessages(
      rawDatagram(
        strings: utf8("db", "main", "items"),
        entries: [(1, commitPayload(regionFlags: 0, tables: [(1, 2, 2, [])]))]
      )
    )
  }
}

@Test
func databaseIPCWireProtocolRejectsDuplicateRegionEntries() {
  // Table names and columns compare without regard to ASCII case, so differently spelled strings
  // can still name the same one.
  let strings = utf8("db", "main", "items", "Items", "title", "TITLE")
  #expect(throws: OrbitIPCWireError.duplicateRegionEntry) {
    try decodeDatabaseIPCMessages(
      rawDatagram(
        strings: strings,
        entries: [(1, commitPayload(regionFlags: 0, tables: [(1, 2, 1, []), (1, 3, 1, [])]))]
      )
    )
  }
  #expect(throws: OrbitIPCWireError.duplicateRegionEntry) {
    try decodeDatabaseIPCMessages(
      rawDatagram(
        strings: strings,
        entries: [(1, commitPayload(regionFlags: 0, tables: [(1, 2, 0, [4, 5])]))]
      )
    )
  }
}

@Test
func databaseIPCWireProtocolBroadensOversizedRegions() throws {
  let message = databaseIPCMessage(
    region: OrbitDatabaseRegion(column: "title", in: "items")
  )
  let exact = try OrbitIPCWireProtocol.encode(message)
  let encoded = try OrbitIPCWireProtocol.encode(message, maximumByteCount: exact.count - 1)

  #expect(try decodeDatabaseIPCMessages(exact) == [message])
  #expect(try decodeDatabaseIPCMessages(encoded) == [databaseIPCMessage(region: .fullDatabase)])
  #expect(throws: OrbitIPCWireError.datagramTooLarge) {
    try OrbitIPCWireProtocol.encode(message, maximumByteCount: 21)
  }
}

@Test
func databaseIPCWireProtocolRejectsOversizedDatabaseIdentifiers() {
  #expect(throws: OrbitIPCWireError.databaseIdentifierTooLong) {
    try OrbitIPCWireProtocol.encode(databaseIPCMessage(String(repeating: "x", count: 65_536)))
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
    try OrbitIPCWireProtocol.decode(Span(_unsafeElements: $0))
  }
}

/// Lays out a datagram field by field, so a test can get any one of them wrong.
private func rawDatagram(
  version: UInt8 = 1,
  flags: UInt8 = 0,
  strings: [[UInt8]],
  entries: [(kind: UInt8, payload: [UInt8])]
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
