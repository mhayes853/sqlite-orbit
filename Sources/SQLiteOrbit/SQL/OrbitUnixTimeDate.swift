#if Foundation
  public import _SQLiteOrbitFoundation

  /// A date stored as whole seconds since 1970, the form SQLite's `unixepoch()` produces.
  ///
  /// The date is truncated to the second when it is stored, and it is read only from an integer.
  ///
  /// ```swift
  /// let query: SQL = """
  ///   SELECT title FROM reminders WHERE created_at > \(OrbitUnixTimeDate(cutoff))
  ///   """
  /// let createdAt = try row[0, as: OrbitUnixTimeDate.self].date
  /// ```
  public struct OrbitUnixTimeDate: OrbitDatabaseValueConvertible, Hashable, Sendable {
    /// The date.
    public var date: Date

    /// Wraps a date to store as Unix time.
    ///
    /// ```swift
    /// let createdAt = OrbitUnixTimeDate(Date())
    /// ```
    ///
    /// - Parameter date: The date.
    public init(_ date: Date) {
      self.date = date
    }

    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      .integer(Int64(date.timeIntervalSince1970))
    }

    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .integer(let seconds) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
      }
      self.init(Date(timeIntervalSince1970: Double(seconds)))
    }
  }
#endif
