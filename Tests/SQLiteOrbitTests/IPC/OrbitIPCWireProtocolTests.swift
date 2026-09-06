import Testing

@testable import SQLiteOrbit

@Test
func databaseIPCWireProtocolHasStableVersionOneEncoding() throws {
  let message = databaseIPCMessage("db")
  let encoded = try OrbitIPCWireProtocol.encode(message)
  #expect(encoded == [0x4F, 0x52, 0x42, 0x54, 1, 1, 0, 2, 0x64, 0x62, 1, 0, 0])
  #expect(try decodeDatabaseIPCMessage(encoded) == message)
}

@Test
func databaseIPCWireProtocolRoundTripsEveryRegionShape() throws {
  let table = OrbitDatabaseRegion(table: "items")
  let column = OrbitDatabaseRegion(column: "title", in: "items")
  let attached = OrbitDatabaseRegion(
    columns: ["first", "second"],
    in: "records",
    schema: "archive"
  )
  let regions = [
    .empty,
    .fullDatabase,
    table,
    column,
    column.union(attached),
    table.subtracting(column),
    OrbitDatabaseRegion.fullDatabase.subtracting(column),
    OrbitDatabaseRegion.fullDatabase.subtracting(table)
  ]

  for region in regions {
    let message = databaseIPCMessage(region: region)
    #expect(try decodeDatabaseIPCMessage(OrbitIPCWireProtocol.encode(message)) == message)
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
  let encoded = try OrbitIPCWireProtocol.encode(databaseIPCMessage("example-database"))
  for count in encoded.indices {
    #expect(throws: OrbitIPCWireError.self) {
      try decodeDatabaseIPCMessage(Array(encoded.prefix(count)))
    }
  }
}

@Test
func databaseIPCWireProtocolRejectsInvalidAndUnsupportedFields() throws {
  let encoded = try OrbitIPCWireProtocol.encode(databaseIPCMessage())
  for (index, value) in [(0, UInt8(0)), (4, 2), (5, 255)] {
    var invalid = encoded
    invalid[index] = value
    #expect(throws: OrbitIPCWireError.self) { try decodeDatabaseIPCMessage(invalid) }
  }

  #expect(throws: OrbitIPCWireError.self) { try decodeDatabaseIPCMessage(encoded + [0]) }
  var invalidUTF8 = encoded
  invalidUTF8[8] = 0xff
  #expect(throws: OrbitIPCWireError.self) { try decodeDatabaseIPCMessage(invalidUTF8) }

  var invalidBoolean = encoded
  invalidBoolean[10] = 2
  #expect(throws: OrbitIPCWireError.invalidBoolean) {
    try decodeDatabaseIPCMessage(invalidBoolean)
  }
}

@Test
func databaseIPCWireProtocolRejectsDuplicateRegionEntries() throws {
  var encoded = try OrbitIPCWireProtocol.encode(
    databaseIPCMessage(region: OrbitDatabaseRegion(column: "title", in: "items"))
  )
  let encodedColumn = Array(encoded.suffix(7))
  encoded[28] = 2
  encoded.append(contentsOf: encodedColumn)

  #expect(throws: OrbitIPCWireError.duplicateRegionEntry) {
    try decodeDatabaseIPCMessage(encoded)
  }
}

@Test
func databaseIPCWireProtocolBroadensOversizedRegions() throws {
  let message = databaseIPCMessage(
    region: OrbitDatabaseRegion(column: "title", in: "items")
  )
  let encoded = try OrbitIPCWireProtocol.encode(message, maximumByteCount: 13)

  #expect(
    try decodeDatabaseIPCMessage(encoded)
      == databaseIPCMessage(region: .fullDatabase)
  )
}

@Test
func databaseIPCWireProtocolRejectsOversizedDatabaseIdentifiers() {
  #expect(throws: OrbitIPCWireError.databaseIdentifierTooLong) {
    try OrbitIPCWireProtocol.encode(databaseIPCMessage(String(repeating: "x", count: 65_536)))
  }
}

private func databaseIPCMessage(
  _ identifier: String = "db",
  region: OrbitDatabaseRegion = .fullDatabase
) -> OrbitIPCMessage {
  .transactionDidCommit(
    .init(databaseIdentifier: .init(rawValue: identifier), region: region)
  )
}

private func decodeDatabaseIPCMessage(_ bytes: [UInt8]) throws -> OrbitIPCMessage {
  try bytes.withUnsafeBufferPointer {
    try OrbitIPCWireProtocol.decode(Span(_unsafeElements: $0))
  }
}
