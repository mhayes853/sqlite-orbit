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
    // Gregorian calendar's own, so the result is the same `Date` to the bit, without the format
    // style's work per call. Years before 1600 are left to the calendar, which switches to the
    // Julian calendar before 1582.
    fileprivate init?(orbitTimestampUTF8 utf8: UnsafeBufferPointer<UInt8>) {
      // Darwin releases before swift-foundation's parser are not known to agree to the bit.
      #if canImport(Darwin)
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else {
          return nil
        }
      #endif
      let count = utf8.count
      guard count == 19 || (21...29).contains(count) else { return nil }
      func digit(_ index: Int) -> Int? {
        let value = utf8[index] &- UInt8(ascii: "0")
        return value < 10 ? Int(value) : nil
      }
      func twoDigits(_ index: Int) -> Int? {
        guard let tens = digit(index), let ones = digit(index + 1) else { return nil }
        return tens * 10 + ones
      }
      guard
        let century = twoDigits(0), let yearOfCentury = twoDigits(2),
        utf8[4] == UInt8(ascii: "-"), let month = twoDigits(5),
        utf8[7] == UInt8(ascii: "-"), let day = twoDigits(8),
        utf8[10] == UInt8(ascii: " "), let hour = twoDigits(11),
        utf8[13] == UInt8(ascii: ":"), let minute = twoDigits(14),
        utf8[16] == UInt8(ascii: ":"), let second = twoDigits(17)
      else { return nil }
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
        guard utf8[19] == UInt8(ascii: ".") else { return nil }
        var nanosecond = 0
        for index in 20..<count {
          guard let digit = digit(index) else { return nil }
          nanosecond = nanosecond * 10 + digit
        }
        for _ in count..<29 { nanosecond *= 10 }
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
