/// Random identifiers spelled as UUIDs, made without Foundation's `UUID`.
enum RandomUUID {
  /// A new random RFC 4122 version 4 UUID, in lowercase: 36 characters, hexadecimal digits in
  /// groups of 8, 4, 4, 4 and 12 separated by hyphens, as Foundation's `UUID().uuidString`
  /// spells one once it is lowercased.
  ///
  /// The bytes come from `SystemRandomNumberGenerator`, which draws on the system's
  /// cryptographically secure source, as Foundation's `UUID()` does.
  static func lowercasedString() -> String {
    var generator = SystemRandomNumberGenerator()
    var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    // The version, 4, in the high nibble of the seventh byte, and the RFC 4122 variant, binary
    // 10, in the top two bits of the ninth.
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80

    var utf8: [UInt8] = []
    utf8.reserveCapacity(36)
    for (index, byte) in bytes.enumerated() {
      if index == 4 || index == 6 || index == 8 || index == 10 {
        utf8.append(UInt8(ascii: "-"))
      }
      LowercaseHexadecimal.append(byte, to: &utf8)
    }
    return String(decoding: utf8, as: UTF8.self)
  }
}
