import Testing

@testable import SQLiteOrbit

@Test
func databaseIPCWireProtocolHasStableVersionOneEncoding() throws {
  let message = databaseIPCMessage("db")
  let encoded = try OrbitIPCWireProtocol.encode(message)
  #expect(encoded == [0x4F, 0x52, 0x42, 0x54, 1, 1, 0, 2, 0x64, 0x62])
  #expect(try decodeDatabaseIPCMessage(encoded) == message)
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
  invalidUTF8[invalidUTF8.count - 1] = 0xff
  #expect(throws: OrbitIPCWireError.self) { try decodeDatabaseIPCMessage(invalidUTF8) }
}

@Test
func databaseIPCWireProtocolRejectsOversizedDatabaseIdentifiers() {
  #expect(throws: OrbitIPCWireError.databaseIdentifierTooLong) {
    try OrbitIPCWireProtocol.encode(databaseIPCMessage(String(repeating: "x", count: 65_536)))
  }
}

private func databaseIPCMessage(_ identifier: String = "db") -> OrbitIPCMessage {
  .transactionDidCommit(.init(databaseIdentifier: .init(rawValue: identifier)))
}

private func decodeDatabaseIPCMessage(_ bytes: [UInt8]) throws -> OrbitIPCMessage {
  try bytes.withUnsafeBufferPointer {
    try OrbitIPCWireProtocol.decode(Span(_unsafeElements: $0))
  }
}
