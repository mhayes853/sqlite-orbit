#if Foundation
  import _SQLiteOrbitFoundation
  import Testing

  @testable import SQLiteOrbit

  // Pins which text reads as a `Date` and the exact `Date` it reads as, so a faster parser can
  // be checked against what `Date.ISO8601FormatStyle` has always produced here.
  @Suite
  struct OrbitISO8601DateTests {
    // Results as `timeIntervalSinceReferenceDate` bit patterns, which is what makes them exact.
    // Recorded from swift-foundation's ISO 8601 parser in Swift 6.3.
    private static let pinned: [(text: String, bitPattern: UInt64?)] = [
      ("2018-04-20 14:47:12.345", 0x41c0_451a_782c_28f6),
      ("2018-04-20 14:47:12", 0x41c0_451a_7800_0000),
      ("2018-01-29 00:08:00.125", 0x41c0_0f4e_b010_0000),
      ("1970-01-01 00:00:00", 0xc1cd_27e4_4000_0000),
      ("2000-02-29 23:59:59.999", 0xc179_36b0_0004_1893),
      ("1600-03-01 00:00:00.5", 0xc207_8f9e_23fc_0000),
      ("9999-12-31 23:59:59.999", 0x424d_62d2_3c7f_ffdf),
      ("2018-04-20 14:47:12.1", 0x41c0_451a_780c_cccd),
      ("2018-04-20 14:47:12.12", 0x41c0_451a_780f_5c29),
      ("2018-04-20 14:47:12.1234", 0x41c0_451a_780f_cb92),
      ("2018-04-20 14:47:12.123456789", 0x41c0_451a_780f_cd6f),
      ("2018-04-20 14:47:12.999999999", 0x41c0_451a_7880_0000),
      ("1969-12-31 23:59:59.999999", 0xc1cd_27e4_4000_0008),
      // Lenient spellings the parser has always accepted: runs of spaces, trailing text (a time
      // zone is ignored, not applied), unpadded or overlong digits, and out-of-range fields
      // that roll over into the next unit.
      ("2018-04-20  14:47:12", 0x41c0_451a_7800_0000),
      ("2018-04-20 14:47:12Z", 0x41c0_451a_7800_0000),
      ("2018-04-20 14:47:12+05:00", 0x41c0_451a_7800_0000),
      ("2018-04-20 14:47:12.345-08:00", 0x41c0_451a_782c_28f6),
      ("2018-04-20 14:47:12.345garbage", 0x41c0_451a_782c_28f6),
      ("2018-04-20 14:47:12 ", 0x41c0_451a_7800_0000),
      ("2018-04-20 14:47:12,345", 0x41c0_451a_7800_0000),
      ("2018-4-2 4:7:2", 0x41c0_38f1_f300_0000),
      ("02018-04-20 14:47:12", 0x41c0_451a_7800_0000),
      ("18-04-20 14:47:12", 0xc22d_22b4_5b20_0000),
      ("2018-02-30 14:47:12", 0x41c0_24cd_b800_0000),
      ("2019-02-29 00:00:00", 0x41c1_1456_c000_0000),
      ("2018-04-20 24:00:00", 0x41c0_455b_4000_0000),
      ("2018-04-20 24:00:01", 0x41c0_455b_4080_0000),
      ("2018-04-20 25:00:00", 0x41c0_4562_4800_0000),
      ("2018-04-20 14:60:00", 0x41c0_451b_f800_0000),
      ("2018-04-20 14:47:60", 0x41c0_451a_9000_0000),
      ("2018-04-20 14:47:61", 0x41c0_451a_9080_0000),
      // Around and before the Gregorian cutover, and past four-digit years.
      ("1582-10-04 12:00:00", 0xc208_9520_6e00_0000),
      ("1582-10-15 12:00:00", 0xc208_9515_e200_0000),
      ("1500-01-01 00:00:00", 0xc20d_7276_1800_0000),
      ("0001-01-01 00:00:00", 0xc22d_63c8_c500_0000),
      ("0000-01-01 00:00:00", 0xc22d_678d_cf00_0000),
      ("10000-01-01 00:00:00", 0x424d_62d2_3c80_0000),
      // Rejected.
      ("2018-04-20T14:47:12", nil),
      ("2018-04-20t14:47:12", nil),
      ("2018-04-20 14:47", nil),
      ("2018-04-20", nil),
      ("", nil),
      (" 2018-04-20 14:47:12", nil),
      ("2018-04-20 14:47:12.", nil),
      ("2018-04-20 14:47:12.1234567891", nil),
      ("2018-13-01 00:00:00", nil),
      ("2018-00-01 00:00:00", nil),
      ("2018-04-00 00:00:00", nil),
      ("2018-04-32 00:00:00", nil),
      ("not a date", nil),
      ("２０１８-04-20 14:47:12", nil)
    ]

    @Test
    func textReadsAsThePinnedDates() throws {
      // Darwin releases before swift-foundation's parser behave differently, and the pins
      // record that parser.
      #if canImport(Darwin)
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return }
      #endif
      for (text, bitPattern) in Self.pinned {
        let parsed = try? Date(orbitISO8601String: text)
        #expect(
          parsed?.timeIntervalSinceReferenceDate.bitPattern == bitPattern,
          "\(text.debugDescription)"
        )
        #expect(OrbitDatabaseValue.text(text).dateValue == parsed)
        #expect((try? Date(orbitDatabaseValue: .text(text))) == parsed)
      }
    }

    @Test
    func textReadsAsFoundationsISO8601FormatStyleReadsIt() {
      var generator = SplitMix64(seed: 0x5EED)
      for _ in 0..<100_000 {
        let text = generator.timestampText()
        let expected = foundationDate(text)
        let parsed = try? Date(orbitISO8601String: text)
        #expect(
          parsed?.timeIntervalSinceReferenceDate.bitPattern
            == expected?.timeIntervalSinceReferenceDate.bitPattern,
          "\(text.debugDescription)"
        )
        if parsed?.timeIntervalSinceReferenceDate.bitPattern
          != expected?.timeIntervalSinceReferenceDate.bitPattern
        {
          return
        }
      }
    }

    private static func style(fractionalSeconds: Bool) -> Date.ISO8601FormatStyle {
      Date.ISO8601FormatStyle().year().month().day()
        .dateTimeSeparator(.space)
        .time(includingFractionalSeconds: fractionalSeconds)
    }

    // The parse this package has always done: fractional seconds first, then without them.
    private func foundationDate(_ text: String) -> Date? {
      if let date = try? Date(text, strategy: Self.style(fractionalSeconds: true)) {
        return date
      }
      return try? Date(text, strategy: Self.style(fractionalSeconds: false))
    }
  }

  private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }

    mutating func number(below bound: Int) -> Int {
      Int(next() % UInt64(bound))
    }

    // Mostly well-formed timestamps with fields just past their ranges, and now and then a
    // character replaced, dropped, or appended.
    mutating func timestampText() -> String {
      func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
      }
      let year = number(below: 4) == 0 ? number(below: 10_000) : 1_550 + number(below: 600)
      var text =
        "\(padded(year, 4))-\(padded(number(below: 14), 2))-\(padded(number(below: 33), 2))"
        + " \(padded(number(below: 26), 2)):\(padded(number(below: 61), 2))"
        + ":\(padded(number(below: 62), 2))"
      let fractionDigits = number(below: 12)
      if fractionDigits > 0 {
        text += "."
        for _ in 0..<(fractionDigits - 1) { text += String(number(below: 10)) }
      }
      var bytes = Array(text.utf8)
      switch number(below: 12) {
      case 0:
        bytes[number(below: bytes.count)] = Array("0T :.-Zx+".utf8)[number(below: 9)]
      case 1:
        bytes.remove(at: number(below: bytes.count))
      case 2:
        bytes += Array(["Z", " ", "+05:00", "x", "0"][number(below: 5)].utf8)
      default:
        break
      }
      return String(decoding: bytes, as: UTF8.self)
    }
  }
#endif
