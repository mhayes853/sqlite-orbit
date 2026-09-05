import Foundation

// How values that SQLite has no native type for are spelled in the database.
//
// These centralize how native connections represent a `Date` or UUID.

@usableFromInline
struct DatabaseIntegerOverflowError<Value: Sendable>: Error {
  @usableFromInline
  let value: Value

  @usableFromInline
  init(value: Value) {
    self.value = value
  }
}

extension Date {
  @usableFromInline
  var orbitISO8601String: String {
    formatted(.iso8601.orbitCurrentTimestamp(includingFractionalSeconds: true))
  }

  @usableFromInline
  init(orbitISO8601String string: String) throws {
    do {
      try self.init(
        string,
        strategy: .iso8601.orbitCurrentTimestamp(includingFractionalSeconds: true)
      )
    } catch {
      try self.init(
        string,
        strategy: .iso8601.orbitCurrentTimestamp(includingFractionalSeconds: false)
      )
    }
  }
}

extension Date.ISO8601FormatStyle {
  @usableFromInline
  func orbitCurrentTimestamp(
    includingFractionalSeconds: Bool
  ) -> Self {
    year().month().day()
      .dateTimeSeparator(.space)
      .time(includingFractionalSeconds: includingFractionalSeconds)
  }
}

extension UUID {
  @usableFromInline
  init?(orbitUTF8 utf8: UnsafeBufferPointer<UInt8>) {
    guard utf8.count == 36 else { return nil }
    var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    let parsed = withUnsafeMutableBytes(of: &raw) { bytes in
      var index = 0
      for byteIndex in 0..<16 {
        if byteIndex == 4 || byteIndex == 6 || byteIndex == 8 || byteIndex == 10 {
          guard utf8[index] == UInt8(ascii: "-") else { return false }
          index += 1
        }
        guard
          let high = orbitHexValue(utf8[index]),
          let low = orbitHexValue(utf8[index + 1])
        else { return false }
        bytes[byteIndex] = high << 4 | low
        index += 2
      }
      return true
    }
    guard parsed else { return nil }
    self.init(uuid: raw)
  }
}

@usableFromInline
func orbitHexValue(_ byte: UInt8) -> UInt8? {
  switch byte {
  case UInt8(ascii: "0")...UInt8(ascii: "9"):
    byte - UInt8(ascii: "0")
  case UInt8(ascii: "a")...UInt8(ascii: "f"):
    byte - UInt8(ascii: "a") + 10
  case UInt8(ascii: "A")...UInt8(ascii: "F"):
    byte - UInt8(ascii: "A") + 10
  default:
    nil
  }
}

@usableFromInline
struct InvalidDatabaseUUIDError: Error {
  @usableFromInline
  init() {}
}
