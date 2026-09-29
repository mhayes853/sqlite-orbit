#if Foundation
  public import _SQLiteOrbitFoundation

  extension OrbitDatabaseValue {
    /// Creates text spelling `date` as an ISO 8601 timestamp.
    ///
    /// The timestamp is in UTC with millisecond precision, such as `2026-01-29 00:08:00.000`,
    /// which is the form SQLite's own date functions read and sort correctly as text.
    ///
    /// ```swift
    /// let value = OrbitDatabaseValue(Date())
    /// ```
    ///
    /// - Parameter date: The date to store.
    public init(_ date: Date) {
      self = .text(date.orbitISO8601String)
    }

    /// Creates text spelling `uuid` in lowercase.
    ///
    /// ```swift
    /// let value = OrbitDatabaseValue(UUID())
    /// ```
    ///
    /// - Parameter uuid: The identifier to store.
    public init(_ uuid: UUID) {
      self = .text(uuid.uuidString.lowercased())
    }

    /// Creates a blob holding `data`'s bytes.
    ///
    /// ```swift
    /// let value = OrbitDatabaseValue(Data([0xde, 0xad]))
    /// ```
    ///
    /// - Parameter data: The bytes to store.
    public init(_ data: Data) {
      self = .blob([UInt8](data))
    }

    /// The date this text spells as an ISO 8601 timestamp, or `nil` for anything else.
    ///
    /// ```swift
    /// let dueDate = row[column: "due_date"]?.dateValue
    /// ```
    public var dateValue: Date? {
      guard case .text(let text) = self else { return nil }
      return try? Date(orbitISO8601String: text)
    }

    /// The UUID this text spells, in either case, or `nil` for anything else.
    ///
    /// ```swift
    /// let id = row[column: "id"]?.uuidValue
    /// ```
    public var uuidValue: UUID? {
      guard case .text(let text) = self else { return nil }
      return UUID(uuidString: text)
    }

    /// The bytes of this blob as `Data`, or `nil` for any other storage class.
    ///
    /// ```swift
    /// let thumbnail = row[column: "thumbnail"]?.dataValue
    /// ```
    public var dataValue: Data? {
      guard case .blob(let bytes) = self else { return nil }
      return Data(bytes)
    }
  }

  extension SQL.StringInterpolation {
    /// Binds a date as ISO 8601 text, as ``OrbitDatabaseValue/init(_:)-(Date)`` spells it.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE due_date < \(Date())"
    /// ```
    ///
    /// - Parameter value: The date to bind.
    public mutating func appendInterpolation(_ value: Date) {
      appendInterpolation(OrbitDatabaseValue(value))
    }

    /// Binds a date as ISO 8601 text, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The date to bind.
    public mutating func appendInterpolation(_ value: Date?) {
      appendInterpolation(value.map(OrbitDatabaseValue.init))
    }

    /// Binds a UUID as lowercase text.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE id = \(id)"
    /// ```
    ///
    /// - Parameter value: The identifier to bind.
    public mutating func appendInterpolation(_ value: UUID) {
      appendInterpolation(OrbitDatabaseValue(value))
    }

    /// Binds a UUID as lowercase text, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The identifier to bind.
    public mutating func appendInterpolation(_ value: UUID?) {
      appendInterpolation(value.map(OrbitDatabaseValue.init))
    }

    /// Binds data as a blob.
    ///
    /// - Parameter value: The bytes to bind.
    public mutating func appendInterpolation(_ value: Data) {
      appendInterpolation(OrbitDatabaseValue(value))
    }

    /// Binds data as a blob, or `NULL` when it is `nil`.
    ///
    /// - Parameter value: The bytes to bind.
    public mutating func appendInterpolation(_ value: Data?) {
      appendInterpolation(value.map(OrbitDatabaseValue.init))
    }
  }
#endif
