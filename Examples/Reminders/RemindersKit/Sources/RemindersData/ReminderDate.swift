import Foundation
import SQLiteOrbit

public nonisolated struct ReminderDate:
  Hashable,
  QueryBindable,
  QueryDecodable,
  RawRepresentable,
  Sendable
{
  public let components: DateComponents

  public var isAllDay: Bool {
    components.hour == nil
  }

  public init?(components: DateComponents) {
    guard
      let year = components.year,
      let month = components.month,
      let day = components.day,
      (components.hour == nil) == (components.minute == nil)
    else { return nil }

    let normalized = DateComponents(
      year: year,
      month: month,
      day: day,
      hour: components.hour,
      minute: components.minute
    )
    guard Self.isValid(normalized) else { return nil }
    self.components = normalized
  }

  public init(date: Date, calendar: Calendar = .current) {
    self.components = calendar.dateComponents(
      [.year, .month, .day],
      from: date
    )
  }

  public init(dateAndTime: Date, calendar: Calendar = .current) {
    self.components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: dateAndTime
    )
  }

  public init?(rawValue: String) {
    let bytes = Array(rawValue.utf8)
    guard
      bytes.count == 10 || bytes.count == 16,
      bytes[4] == UInt8(ascii: "-"),
      bytes[7] == UInt8(ascii: "-"),
      let year = Self.integer(in: 0..<4, from: bytes),
      let month = Self.integer(in: 5..<7, from: bytes),
      let day = Self.integer(in: 8..<10, from: bytes)
    else { return nil }

    if bytes.count == 10 {
      self.init(components: DateComponents(year: year, month: month, day: day))
    } else {
      guard
        bytes[10] == UInt8(ascii: "T"),
        bytes[13] == UInt8(ascii: ":"),
        let hour = Self.integer(in: 11..<13, from: bytes),
        let minute = Self.integer(in: 14..<16, from: bytes)
      else { return nil }
      self.init(
        components: DateComponents(
          year: year,
          month: month,
          day: day,
          hour: hour,
          minute: minute
        )
      )
    }
  }

  public var rawValue: String {
    let date = String(
      format: "%04d-%02d-%02d",
      components.year!,
      components.month!,
      components.day!
    )
    guard let hour = components.hour, let minute = components.minute else {
      return date
    }
    return date + String(format: "T%02d:%02d", hour, minute)
  }

  public func date(in calendar: Calendar = .current) -> Date? {
    var components = components
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    return components.date
  }

  private static func integer(
    in range: Range<Int>,
    from bytes: [UInt8]
  ) -> Int? {
    var value = 0
    for byte in bytes[range] {
      guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9")
      else { return nil }
      value = value * 10 + Int(byte - UInt8(ascii: "0"))
    }
    return value
  }

  private static func isValid(_ components: DateComponents) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: components) else { return false }
    let fields: Set<Calendar.Component> =
      components.hour == nil
      ? [.year, .month, .day]
      : [.year, .month, .day, .hour, .minute]
    let validated = calendar.dateComponents(fields, from: date)
    return validated.year == components.year
      && validated.month == components.month
      && validated.day == components.day
      && validated.hour == components.hour
      && validated.minute == components.minute
  }
}
