/// How a connection waits for a lock another connection or process holds before reporting
/// `SQLITE_BUSY`.
///
/// SQLite keeps one busy handler per connection and implements its busy timeout as one, so a
/// connection waits by exactly one policy at a time.
///
/// ```swift
/// var configuration = SQLiteConfiguration.default
/// configuration.busyPolicy = .timeout(.seconds(10))
///
/// configuration.busyPolicy = .handler { attempt in
///   guard attempt <= 50 else { return false }
///   Thread.sleep(forTimeInterval: 0.01)
///   return true
/// }
/// ```
public enum SQLiteBusyPolicy: Sendable {
  /// Waits up to the given duration, counted in whole milliseconds: `sqlite3_busy_timeout`.
  ///
  /// A zero or negative duration waits not at all, and one longer than SQLite can express waits
  /// as long as ``waitIndefinitely`` does.
  case timeout(Duration)

  /// Waits the longest SQLite's busy timeout can express: `Int32.max` milliseconds, about 24.8
  /// days.
  ///
  /// SQLite takes the timeout as a 32-bit count of milliseconds, so even this wait ends
  /// eventually.
  case waitIndefinitely

  /// Asks `handler`, each time the lock is still held, whether to keep waiting for it:
  /// `sqlite3_busy_handler`.
  ///
  /// Rather than a fixed deadline, the handler answers `true` to wait and try once more, or
  /// `false` to give up, which surfaces `SQLITE_BUSY` to the statement. It is the hook for backing
  /// off, for giving up on a deadline of the caller's own, and for reporting contention. The
  /// handler does whatever waiting there is itself; SQLite tries again as soon as it returns.
  ///
  /// The handler is invoked on the thread that is running the blocked statement, with `attempt`
  /// counting from `1` and rising for as long as that one statement keeps waiting. It must not
  /// touch the connection it was blocked on.
  ///
  /// Using this with a ``SQLiteLibrary`` without ``SQLiteLibrary/busyHandler`` fails with a
  /// ``SQLiteFeatureUnavailableError`` for ``SQLiteLibraryFeature/busyHandler``.
  case handler(@Sendable (_ attempt: Int) -> Bool)
}

extension SQLiteBusyPolicy {
  /// The timeout in whole milliseconds as SQLite's busy timeout takes it, clamped to what an
  /// `Int32` holds, with a zero or negative duration meaning no wait at all, or `nil` for a
  /// handler.
  var timeoutMilliseconds: Int32? {
    switch self {
    case .waitIndefinitely:
      return .max
    case .timeout(let duration):
      let components = duration.components
      guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
      guard components.seconds <= Int64(Int32.max) / 1000 else { return .max }
      let milliseconds =
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
      return Int32(clamping: milliseconds)
    case .handler:
      return nil
    }
  }
}
