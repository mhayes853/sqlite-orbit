/// Bytes spelled in lowercase hexadecimal, two digits to a byte, high digit first, as a UUID, a
/// blob literal and a coordination key spell them.
enum LowercaseHexadecimal {
  /// Appends the two digits that spell `byte`, as UTF-8, to `utf8`.
  static func append(_ byte: UInt8, to utf8: inout [UInt8]) {
    utf8.append(digit(byte >> 4))
    utf8.append(digit(byte & 0x0F))
  }

  /// The digits that spell `bytes`, in order.
  static func string(_ bytes: some Sequence<UInt8>) -> String {
    var utf8: [UInt8] = []
    utf8.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
      append(byte, to: &utf8)
    }
    return String(decoding: utf8, as: UTF8.self)
  }

  private static func digit(_ nibble: UInt8) -> UInt8 {
    nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + nibble - 10
  }
}
