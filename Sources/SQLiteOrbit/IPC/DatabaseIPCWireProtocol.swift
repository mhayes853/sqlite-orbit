enum DatabaseIPCWireError: Error, Equatable {
  case databaseIdentifierTooLong
  case invalidMagic
  case invalidUTF8
  case trailingBytes
  case truncated
  case unsupportedMessageKind(UInt8)
  case unsupportedProtocolVersion(UInt8)
}

enum DatabaseIPCWireProtocol {
  static func encode(_ message: DatabaseIPCMessage) throws -> [UInt8] {
    let database = Array(message.databaseIdentifier.rawValue.utf8)
    guard let count = UInt16(exactly: database.count) else {
      throw DatabaseIPCWireError.databaseIdentifierTooLong
    }
    return [
      0x4F, 0x52, 0x42, 0x54,  // ORBT
      1,
      Self.kind(of: message),
      UInt8(truncatingIfNeeded: count >> 8),
      UInt8(truncatingIfNeeded: count)
    ] + database
  }

  static func decode(_ bytes: Span<UInt8>) throws -> DatabaseIPCMessage {
    guard bytes.count >= 8 else { throw DatabaseIPCWireError.truncated }
    guard bytes[0] == 0x4F, bytes[1] == 0x52, bytes[2] == 0x42, bytes[3] == 0x54 else {
      throw DatabaseIPCWireError.invalidMagic
    }
    guard bytes[4] == 1 else {
      throw DatabaseIPCWireError.unsupportedProtocolVersion(bytes[4])
    }

    let count = Int(UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
    guard count <= bytes.count - 8 else { throw DatabaseIPCWireError.truncated }
    guard count == bytes.count - 8 else { throw DatabaseIPCWireError.trailingBytes }
    let database = bytes.extracting(8..<bytes.count)
      .withUnsafeBufferPointer {
        String(validating: $0, as: UTF8.self)
      }
    guard let database else { throw DatabaseIPCWireError.invalidUTF8 }

    let databaseIdentifier = DatabaseIdentifier(rawValue: database)
    switch bytes[5] {
    case 1:
      return .transactionDidCommit(.init(databaseIdentifier: databaseIdentifier))
    default:
      throw DatabaseIPCWireError.unsupportedMessageKind(bytes[5])
    }
  }

  private static func kind(of message: DatabaseIPCMessage) -> UInt8 {
    switch message {
    case .transactionDidCommit: 1
    }
  }
}
