#if Foundation
  public import _SQLiteOrbitFoundation

  /// A date stored as whole seconds since 1970, the form SQLite's `unixepoch()` produces.
  ///
  /// The date is truncated to the second when it is stored, and it is read only from an integer.
  ///
  /// ```swift
  /// let query: SQL = """
  ///   SELECT title FROM reminders WHERE created_at > \(OrbitDatabaseUnixTime(cutoff))
  ///   """
  /// let createdAt = try row[0, as: OrbitDatabaseUnixTime.self].date
  /// ```
  public struct OrbitDatabaseUnixTime: OrbitDatabaseValueConvertible, Hashable, Sendable {
    /// The date.
    public var date: Date

    /// Wraps a date to store as Unix time.
    ///
    /// ```swift
    /// let createdAt = OrbitDatabaseUnixTime(Date())
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

  /// A date stored as a fractional Julian day number, the form SQLite's `julianday()` produces.
  ///
  /// The date is read only from a real number.
  ///
  /// ```swift
  /// let query: SQL = """
  ///   SELECT title FROM reminders WHERE due_at < \(OrbitDatabaseJulianDay(cutoff))
  ///   """
  /// let dueAt = try row[0, as: OrbitDatabaseJulianDay.self].date
  /// ```
  public struct OrbitDatabaseJulianDay: OrbitDatabaseValueConvertible, Hashable, Sendable {
    /// The date.
    public var date: Date

    /// Wraps a date to store as a Julian day.
    ///
    /// ```swift
    /// let dueAt = OrbitDatabaseJulianDay(Date())
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
