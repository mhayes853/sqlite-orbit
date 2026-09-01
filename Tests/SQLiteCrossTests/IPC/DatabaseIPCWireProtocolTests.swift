import Testing

@testable import SQLiteCross

@Test
func databaseIPCWireProtocolHasStableVersionOneEncoding() throws {
  let message = databaseIPCMessage("db")
  let encoded = try DatabaseIPCWireProtocol.encode(message)
  #expect(encoded == [0x53, 0x51, 0x43, 0x58, 1, 1, 0, 2, 0x64, 0x62])
  #expect(try decodeDatabaseIPCMessage(encoded) == message)
}

@Test
func databaseIPCWireProtocolRejectsEveryTruncatedPrefix() throws {
  let encoded = try DatabaseIPCWireProtocol.encode(databaseIPCMessage("example-database"))
  for count in encoded.indices {
    #expect(throws: DatabaseIPCWireError.self) {
      try decodeDatabaseIPCMessage(Array(encoded.prefix(count)))
    }
  }
}

@Test
func databaseIPCWireProtocolRejectsInvalidAndUnsupportedFields() throws {
  let encoded = try DatabaseIPCWireProtocol.encode(databaseIPCMessage())
  for (index, value) in [(0, UInt8(0)), (4, 2), (5, 255)] {
    var invalid = encoded
    invalid[index] = value
    #expect(throws: DatabaseIPCWireError.self) { try decodeDatabaseIPCMessage(invalid) }
  }

  #expect(throws: DatabaseIPCWireError.self) { try decodeDatabaseIPCMessage(encoded + [0]) }
  var invalidUTF8 = encoded
  invalidUTF8[invalidUTF8.count - 1] = 0xff
  #expect(throws: DatabaseIPCWireError.self) { try decodeDatabaseIPCMessage(invalidUTF8) }
}

@Test
func databaseIPCWireProtocolRejectsOversizedDatabaseIdentifiers() {
  #expect(throws: DatabaseIPCWireError.databaseIdentifierTooLong) {
    try DatabaseIPCWireProtocol.encode(databaseIPCMessage(String(repeating: "x", count: 65_536)))
  }
}

private func databaseIPCMessage(_ identifier: String = "db") -> DatabaseIPCMessage {
  .transactionDidCommit(.init(databaseIdentifier: .init(rawValue: identifier)))
}

private func decodeDatabaseIPCMessage(_ bytes: [UInt8]) throws -> DatabaseIPCMessage {
  try bytes.withUnsafeBufferPointer {
    try DatabaseIPCWireProtocol.decode(Span(_unsafeElements: $0))
  }
}
