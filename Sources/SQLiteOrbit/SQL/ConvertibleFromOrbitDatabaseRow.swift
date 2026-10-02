/// A value that can be initialized from a borrowed database result row.
///
/// The initializer must finish reading before it returns. The resulting value owns its data and
/// can outlive the row and transaction.
///
/// ```swift
/// struct ReminderSummary: ConvertibleFromOrbitDatabaseRow {
///   let id: Int
///   let title: String
///
///   init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
///     orbitDatabaseRow row: borrowing Row
///   ) throws {
///     id = try row[column: "id", as: Int.self]
///     title = try row[column: "title", as: String.self]
///   }
/// }
/// ```
public protocol ConvertibleFromOrbitDatabaseRow {
  /// Creates an owned value from a row that is valid only for this call.
  init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
    orbitDatabaseRow row: borrowing Row
  ) throws
}
