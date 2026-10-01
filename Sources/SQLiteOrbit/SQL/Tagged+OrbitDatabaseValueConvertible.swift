#if Tagged
  public import Tagged

  /// A tagged value is stored as its raw value is.
  ///
  /// ```swift
  /// struct Reminder {
  ///   typealias ID = Tagged<Self, Int>
  ///   let id: ID
  /// }
  ///
  /// let query: SQL = "SELECT title FROM reminders WHERE id = \(reminder.id)"
  /// ```
  extension Tagged: ConvertibleToOrbitDatabaseValue
  where RawValue: ConvertibleToOrbitDatabaseValue {}

  /// A tagged value is read as its raw value is.
  ///
  /// ```swift
  /// let ids = try transaction.fetchAll("SELECT id FROM reminders", as: Reminder.ID.self)
  /// ```
  extension Tagged: ConvertibleFromOrbitDatabaseValue
  where RawValue: ConvertibleFromOrbitDatabaseValue {}
#endif
