#if Foundation
  import _SQLiteOrbitFoundation

  // How values that SQLite has no native type for are spelled in the database.
  //
  // These centralize how native connections represent a `Date` or UUID.

  extension Date {
    @usableFromInline
    var orbitISO8601String: String {
      formatted(.iso8601.orbitCurrentTimestamp(includingFractionalSeconds: true))
    }

    @usableFromInline
    init(orbitISO8601String string: String) throws {
      if let date = string.utf8.withContiguousStorageIfAvailable(Date.init(orbitTimestampUTF8:)),
        let date
      {
        self = date
      } else {
        try self.init(orbitFormatStyleString: string)
      }
    }

    // Reads text straight out of a column, so the common spelling never becomes a `String`.
    @usableFromInline
    init(orbitISO8601UTF8 utf8: UnsafeBufferPointer<UInt8>) throws {
      if let date = Date(orbitTimestampUTF8: utf8) {
        self = date
      } else {
        try self.init(orbitFormatStyleString: String(decoding: utf8, as: UTF8.self))
      }
    }

    // The parser every spelling has always gone through. It is lenient: fields may be unpadded
    // or out of range, and text after the seconds is ignored.
    private init(orbitFormatStyleString string: String) throws {
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

  extension Date {
    // Parses exactly `yyyy-MM-dd HH:mm:ss` with up to nine fractional digits, in UTC, and returns
    // `nil` for anything else so that the format style decides it. The arithmetic is the
    // Gregorian calendar's own, so the result is the same `Date` to the bit as swift-foundation's
    // parser, without the format style's work per call. Years before 1600 are left to the
    // calendar, which switches to the Julian calendar before 1582.
    //
    // This runs on every platform, including Darwin releases before 26, whose Foundation predates
    // swift-foundation's parser and may round or truncate fractional seconds differently. There,
    // these spellings now read as they do everywhere else rather than as that Foundation read them.
    init?(orbitTimestampUTF8 utf8: UnsafeBufferPointer<UInt8>) {
      let count = utf8.count
      guard count == 19 || (21...29).contains(count) else { return nil }
      // Eight bytes at a time, as integers whose low byte is the first. Three overlapping loads
      // cover the 19 bytes before any fraction: "yyyy-MM-", "dd HH:mm" and "HH:mm:ss".
      let bytes = UnsafeRawBufferPointer(utf8)
      func load(_ offset: Int) -> UInt64 {
        UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
      }
      // XORing each byte with what it should be leaves 0 through 9 where a digit belongs, and 0
      // where the expected separator is.
      let dateBytes = load(0) ^ 0x2D30_302D_3030_3030
      let dayBytes = load(8) ^ 0x3030_3A30_3020_3030
      let timeBytes = load(11) ^ 0x3030_3A30_303A_3030
      guard
        orbitNonDigits(dateBytes, separators: 0xFF00_00FF_0000_0000)
          | orbitNonDigits(dayBytes, separators: 0x0000_FF00_00FF_0000)
          | orbitNonDigits(timeBytes, separators: 0x0000_FF00_00FF_0000) == 0
      else { return nil }
      let datePairs = orbitDigitPairs(dateBytes)
      let timePairs = orbitDigitPairs(timeBytes)
      let century = Int(datePairs & 0xFF)
      let yearOfCentury = Int(datePairs >> 16 & 0xFF)
      let month = Int(datePairs >> 40 & 0xFF)
      let day = Int(orbitDigitPairs(dayBytes) & 0xFF)
      let hour = Int(timePairs & 0xFF)
      let minute = Int(timePairs >> 24 & 0xFF)
      let second = Int(timePairs >> 48 & 0xFF)
      let year = century * 100 + yearOfCentury
      guard year >= 1600, (1...12).contains(month), hour < 24, minute < 60, second < 60
      else { return nil }
      let daysInMonth =
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
      guard (1...daysInMonth).contains(day) else { return nil }

      var secondsInDay = Double(hour * 3600 + minute * 60 + second)
      if count > 19 {
        // The last eight bytes end with the fraction's last digits, up to eight of them.
        // Shifting out the bytes before those digits leaves zeros after them, which pads the
        // fraction to eight digits as the scale requires.
        let fractionDigits = count - 20
        let fractionBytes =
          (load(count - 8) ^ 0x3030_3030_3030_3030) >> (8 * (8 - Swift.min(fractionDigits, 8)))
        // A ninth digit comes before those eight bytes, so it is checked on its own.
        let firstDigit = utf8[20] &- UInt8(ascii: "0")
        guard utf8[19] == UInt8(ascii: "."), orbitNonDigits(fractionBytes, separators: 0) == 0,
          fractionDigits < 9 || firstDigit < 10
        else { return nil }
        let lastEight = Int(orbitEightDigits(fractionBytes))
        let nanosecond =
          fractionDigits == 9 ? Int(firstDigit) * 100_000_000 + lastEight : lastEight * 10
        // Added as the calendar adds it, in one rounding, then added to midnight in another.
        secondsInDay += Double(nanosecond) / 1_000_000_000
      }

      // Days since 1970-01-01, from Howard Hinnant's `days_from_civil`.
      let marchYear = month <= 2 ? year - 1 : year
      let era = marchYear / 400
      let yearOfEra = marchYear - era * 400
      let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
      let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
      let daysSince1970 = era * 146_097 + dayOfEra - 719_468
      // 2001-01-01, the reference date, is 11,323 days after 1970-01-01.
      let midnight = Double((daysSince1970 - 11_323) * 86_400)
      self.init(timeIntervalSinceReferenceDate: midnight + secondsInDay)
    }
  }

  // Nonzero unless every byte is 0 through 9, or 0 where `separators` has 0xFF.
  private func orbitNonDigits(_ bytes: UInt64, separators: UInt64) -> UInt64 {
    // A digit passes when neither it nor it plus 6 reaches 16. Adding 6 carries into the next
    // byte only from a byte of 0xFA or more, which fails by itself.
    let digits: UInt64 = ~separators
    let highNibbles: UInt64 = bytes | (bytes &+ (digits & 0x0606_0606_0606_0606))
    return highNibbles & (digits & 0xF0F0_F0F0_F0F0_F0F0 | separators)
  }

  // Makes each byte of digits ten times itself plus the next, the two-digit number starting there.
  // Digits are at most 9, so no byte reaches 100 or carries into the next.
  private func orbitDigitPairs(_ digits: UInt64) -> UInt64 {
    digits &* 10 &+ digits >> 8
  }

  // The number eight digits spell, the first in the low byte, from Daniel Lemire's SWAR parse.
  private func orbitEightDigits(_ digits: UInt64) -> UInt64 {
    let pairs = orbitDigitPairs(digits)
    // Pairs 0 and 2 are scaled by 10^6 and 10^2, pairs 1 and 3 by 10^4 and 1, and their sum
    // lands in the high 32 bits without carrying out of them.
    let mask: UInt64 = 0x0000_00FF_0000_00FF
    let evenPairs: UInt64 = (pairs & mask) &* (1_000_000 << 32 | 100)
    let oddPairs: UInt64 = (pairs >> 16 & mask) &* (10_000 << 32 | 1)
    return (evenPairs &+ oddPairs) >> 32
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
  struct InvalidOrbitDatabaseUUIDError: Error {
    @usableFromInline
    init() {}
  }
#endif
