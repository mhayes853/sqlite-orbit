/// How long a connection waits for a lock another connection or process holds before reporting
/// `SQLITE_BUSY`.
///
/// ```swift
/// var configuration = SQLiteConfiguration.default
/// configuration.busyTimeout = .limit(.seconds(10))
/// ```
public enum SQLiteBusyTimeout: Hashable, Sendable {
  /// Waits up to the given duration, counted in whole milliseconds.
  ///
  /// A negative duration waits not at all, and one longer than SQLite can express waits as long
  /// as ``unlimited`` does.
  case limit(Duration)

  /// Waits as long as SQLite's busy timeout can express.
  ///
  /// SQLite takes the timeout as a 32-bit count of milliseconds, so this is `Int32.max`
  /// milliseconds, about 24.8 days, rather than forever.
  case unlimited

  /// The timeout as SQLite's busy timeout takes it: whole milliseconds, clamped to what an `Int32`
  /// holds, with a negative duration meaning no wait at all.
  var milliseconds: Int32 {
    switch self {
    case .unlimited:
      return .max
    case .limit(let duration):
      let components = duration.components
      guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
      guard components.seconds < Int64(Int32.max) / 1000 else { return .max }
      let milliseconds =
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
      return Int32(clamping: milliseconds)
    }
  }
}
