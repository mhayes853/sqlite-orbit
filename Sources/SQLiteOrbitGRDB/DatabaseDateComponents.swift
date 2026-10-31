#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// Date components read from or written to the database in one of SQLite's date formats.
  public struct DatabaseDateComponents: Sendable {
    /// The SQLite date formats.
    public enum Format: String, Sendable {
      case YMD = "yyyy-MM-dd"
      case YMD_HM = "yyyy-MM-dd HH:mm"
      case YMD_HMS = "yyyy-MM-dd HH:mm:ss"
      case YMD_HMSS = "yyyy-MM-dd HH:mm:ss.SSS"
      case HM = "HH:mm"
      case HMS = "HH:mm:ss"
      case HMSS = "HH:mm:ss.SSS"

      var hasYMDComponents: Bool {
        switch self {
        case .YMD, .YMD_HM, .YMD_HMS, .YMD_HMSS: true
        case .HM, .HMS, .HMSS: false
        }
      }
    }

    /// The date components.
    public let dateComponents: DateComponents

    /// The database format.
    public let format: Format

    /// Creates components stored with the given format.
    public init(_ dateComponents: DateComponents, format: Format) {
      self.dateComponents = dateComponents
      self.format = format
    }
  }

  extension DatabaseDateComponents: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
      let c = dateComponents
      var parts: [String] = []
      if format.hasYMDComponents {
        parts.append(String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1))
      }
      switch format {
      case .YMD:
        break
      case .YMD_HM, .HM:
        parts.append(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
      case .YMD_HMS, .HMS:
        parts.append(String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0))
      case .YMD_HMSS, .HMSS:
        let milliseconds = Int((Double(c.nanosecond ?? 0) / 1_000_000).rounded())
        parts.append(
          String(
            format: "%02d:%02d:%02d.%03d",
            c.hour ?? 0,
            c.minute ?? 0,
            c.second ?? 0,
            milliseconds
          )
        )
      }
      return parts.joined(separator: " ").databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DatabaseDateComponents? {
      String.fromDatabaseValue(dbValue).flatMap(parseSQLiteDate)
    }
  }

  extension DatabaseDateComponents: Codable {
    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      guard let components = parseSQLiteDate(string) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Unable to initialise databaseDateComponent"
        )
      }
      self = components
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(String.fromDatabaseValue(databaseValue)!)
    }
  }

  // Parses the date formats SQLite understands, as GRDB does:
  // `YYYY-MM-DD`, optionally followed by a space or `T` and a time; or a time alone.
  // Times are `HH:MM`, `HH:MM:SS`, or `HH:MM:SS.S...`, optionally followed by `Z` or `±HH:MM`.
  // Fractional seconds keep millisecond precision.
  func parseSQLiteDate(_ string: String) -> DatabaseDateComponents? {
    var scanner = DateScanner(Array(string.utf8))
    guard scanner.bytes.count >= 5 else { return nil }
    var components = DateComponents()
    let format: DatabaseDateComponents.Format
    if scanner.bytes.count > 4 && scanner.bytes[4] == UInt8(ascii: "-") {
      guard let year = scanner.digits(4), scanner.skip("-"),
        let month = scanner.digits(2), scanner.skip("-"),
        let day = scanner.digits(2)
      else { return nil }
      components.year = year
      components.month = month
      components.day = day
      if scanner.isAtEnd {
        format = .YMD
      } else {
        guard scanner.skip(" ") || scanner.skip("T"),
          let time = scanTime(&scanner, into: &components)
        else { return nil }
        switch time {
        case .HM: format = .YMD_HM
        case .HMS: format = .YMD_HMS
        default: format = .YMD_HMSS
        }
      }
    } else if scanner.bytes[2] == UInt8(ascii: ":") {
      guard let time = scanTime(&scanner, into: &components) else { return nil }
      format = time
    } else {
      return nil
    }
    guard scanner.isAtEnd else { return nil }
    return DatabaseDateComponents(components, format: format)
  }

  private func scanTime(
    _ scanner: inout DateScanner,
    into components: inout DateComponents
  ) -> DatabaseDateComponents.Format? {
    guard let hour = scanner.digits(2), scanner.skip(":"), let minute = scanner.digits(2) else {
      return nil
    }
    components.hour = hour
    components.minute = minute
    if scanner.isAtEnd || scanTimeZone(&scanner, into: &components) { return .HM }
    guard scanner.skip(":"), let second = scanner.digits(2) else { return nil }
    components.second = second
    if scanner.isAtEnd || scanTimeZone(&scanner, into: &components) { return .HMS }
    guard scanner.skip(".") else { return nil }
    var fraction = 0
    var count = 0
    while let digit = scanner.digit() {
      if count < 3 {
        fraction = fraction * 10 + digit
      }
      count += 1
    }
    guard count > 0 else { return nil }
    for _ in min(count, 3)..<3 { fraction *= 10 }
    components.nanosecond = fraction * 1_000_000
    _ = scanTimeZone(&scanner, into: &components)
    return .HMSS
  }

  private func scanTimeZone(
    _ scanner: inout DateScanner,
    into components: inout DateComponents
  ) -> Bool {
    if scanner.skip("Z") {
      components.timeZone = TimeZone(secondsFromGMT: 0)
      return true
    }
    let start = scanner.position
    for (sign, multiplier) in [("+", 1), ("-", -1)] where scanner.skip(Unicode.Scalar(sign)!) {
      if let hour = scanner.digits(2), scanner.skip(":"), let minute = scanner.digits(2) {
        components.timeZone = TimeZone(secondsFromGMT: multiplier * (hour * 3600 + minute * 60))
        return true
      }
      scanner.position = start
    }
    return false
  }

  private struct DateScanner {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) {
      self.bytes = bytes
    }

    var isAtEnd: Bool { position == bytes.count }

    mutating func skip(_ scalar: Unicode.Scalar) -> Bool {
      guard position < bytes.count, bytes[position] == UInt8(ascii: scalar) else { return false }
      position += 1
      return true
    }

    mutating func digit() -> Int? {
      guard position < bytes.count, (48...57).contains(bytes[position]) else { return nil }
      defer { position += 1 }
      return Int(bytes[position] - 48)
    }

    mutating func digits(_ count: Int) -> Int? {
      var value = 0
      for _ in 0..<count {
        guard let digit = digit() else { return nil }
        value = value * 10 + digit
      }
      return value
    }
  }

  // The calendar used for stored dates.
  let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  extension Date {
    init?(databaseDateComponents components: DatabaseDateComponents) {
      // Times without a date do not identify a moment.
      guard components.format.hasYMDComponents,
        let date = utcCalendar.date(from: components.dateComponents)
      else { return nil }
      self = date
    }

    /// Creates a date from a Julian day number, using SQLite's algorithm.
    public init?(julianDay: Double) {
      let milliseconds = Int64(julianDay * 86_400_000)
      let z = Int((milliseconds + 43_200_000) / 86_400_000)
      var a = Int((Double(z) - 1_867_216.25) / 36_524.25)
      a = z + 1 + a - (a / 4)
      let b = a + 1524
      let c = Int((Double(b) - 122.1) / 365.25)
      let d = (36525 * (c & 32767)) / 100
      let e = Int(Double(b - d) / 30.6001)
      let day = b - d - Int(30.6001 * Double(e))
      let month = e < 14 ? e - 1 : e - 13
      let year = month > 2 ? c - 4716 : c - 4715
      var s = Int((milliseconds + 43_200_000) % 86_400_000)
      var second = Double(s) / 1000
      s = Int(second)
      second -= Double(s)
      let hour = s / 3600
      s -= hour * 3600
      let minute = s / 60
      second += Double(s - minute * 60)
      var components = DateComponents()
      components.year = year
      components.month = month
      components.day = day
      components.hour = hour
      components.minute = minute
      components.second = Int(second)
      components.nanosecond = Int((second - Double(Int(second))) * 1e9)
      guard let date = utcCalendar.date(from: components) else { return nil }
      self = date
    }
  }
#endif
