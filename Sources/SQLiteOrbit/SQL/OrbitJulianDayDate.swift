#if Foundation
  public import _SQLiteOrbitFoundation

  /// A date stored as a fractional Julian day number, the form SQLite's `julianday()` produces.
  ///
  /// The date is read only from a real number.
  ///
  /// ```swift
  /// let query: SQL = """
  ///   SELECT title FROM reminders WHERE due_at < \(OrbitJulianDayDate(cutoff))
  ///   """
  /// let dueAt = try row[0, as: OrbitJulianDayDate.self].date
  /// ```
  public struct OrbitJulianDayDate: OrbitDatabaseValueConvertible, Hashable, Sendable {
    /// The date.
    public var date: Date

    /// Wraps a date to store as a Julian day.
    ///
    /// ```swift
    /// let dueAt = OrbitJulianDayDate(Date())
    /// ```
    ///
    /// - Parameter date: The date.
    public init(_ date: Date) {
      self.date = date
    }

    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      .real(2440587.5 + date.timeIntervalSince1970 / 86400)
    }

    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .real(let day) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
      }
      self.init(Date(timeIntervalSince1970: (day - 2440587.5) * 86400))
    }
  }
#endif
