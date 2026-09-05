enum OrbitIPCWireError: Error, Equatable {
  case databaseIdentifierTooLong
  case invalidMagic
  case invalidUTF8
  case trailingBytes
  case truncated
  case unsupportedMessageKind(UInt8)
  case unsupportedProtocolVersion(UInt8)
}

enum OrbitIPCWireProtocol {
  static func encode(_ message: OrbitIPCMessage) throws -> [UInt8] {
    let database = Array(message.databaseIdentifier.rawValue.utf8)
    guard let count = UInt16(exactly: database.count) else {
      throw OrbitIPCWireError.databaseIdentifierTooLong
    }
    return [
      0x4F, 0x52, 0x42, 0x54,  // ORBT
      1,
      Self.kind(of: message),
      UInt8(truncatingIfNeeded: count >> 8),
      UInt8(truncatingIfNeeded: count)
    ] + database
  }

  static func decode(_ bytes: Span<UInt8>) throws -> OrbitIPCMessage {
    guard bytes.count >= 8 else { throw OrbitIPCWireError.truncated }
    guard bytes[0] == 0x4F, bytes[1] == 0x52, bytes[2] == 0x42, bytes[3] == 0x54 else {
      throw OrbitIPCWireError.invalidMagic
    }
    guard bytes[4] == 1 else {
      throw OrbitIPCWireError.unsupportedProtocolVersion(bytes[4])
    }

    let count = Int(UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
    guard count <= bytes.count - 8 else { throw OrbitIPCWireError.truncated }
    guard count == bytes.count - 8 else { throw OrbitIPCWireError.trailingBytes }
    let database = bytes.extracting(8..<bytes.count)
      .withUnsafeBufferPointer {
        String(validating: $0, as: UTF8.self)
      }
    guard let database else { throw OrbitIPCWireError.invalidUTF8 }

    let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: database)
    switch bytes[5] {
    case 1:
      return .transactionDidCommit(.init(databaseIdentifier: databaseIdentifier))
    default:
      throw OrbitIPCWireError.unsupportedMessageKind(bytes[5])
    }
  }

  private static func kind(of message: OrbitIPCMessage) -> UInt8 {
    switch message {
    case .transactionDidCommit: 1
    }
  }
}
