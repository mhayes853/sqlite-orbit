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
    guard
      let match = rawValue.wholeMatch(
        of: /([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2}))?/
      )
    else { return nil }
    self.init(
      components: DateComponents(
        year: Int(match.1),
        month: Int(match.2),
        day: Int(match.3),
        hour: match.4.flatMap { Int($0) },
        minute: match.5.flatMap { Int($0) }
      )
    )
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
}
